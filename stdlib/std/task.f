// std.task runs concurrent work as tasks inside scopes (RFC-005).
//
// `concurrent` opens a scope: it runs a body with the scope and returns the body's value once every
// task the scope started has finished. Inside the body, `spawn` starts a task and returns a `Task`,
// whose `await` yields the task's result; `launch` starts a task that has no result, and `join`
// waits for every task the scope started. Called outside any scope, `concurrent` starts the runtime
// and blocks the calling thread; called inside a task, it opens a nested scope and blocks only that
// task.
//
// Cancellation is cooperative. `cancel` cancels a scope's tasks and every scope nested in them,
// never the scope's parent. A task observes cancellation only by asking, through `is_cancelled`,
// `check_cancelled` or `yield_now`. Nothing interrupts a task, so it returns normally and its
// deferred calls run.
//
// A task's function may refer to locals of the body that started it. Therefore:
//
//   - A scope's body must not return while a task it started is still running. Await or join
//     first; a body that returns early panics.
//   - A `Task` must not be used after its scope has ended. Awaiting or starting it then panics.
//
// A panic inside a task ends the process. Under the test runner it fails the test that opened the
// outermost scope instead.

import std.allocator
import std.option
import std.result
import std.runtime.coro
import std.test

// A Job is a scope's cancellation state. A job counts as cancelled when it, or any job above it, is
// cancelled.
pub type Job = struct {
    // The job of the enclosing scope, or null for an outermost scope.
    parent: &Job?
    cancelled: bool
}

// job is the job of the innermost scope the current code runs in, or null outside every scope.
pub context job: &Job? = null

// Start says when a spawned task begins running.
pub type Start = enum {
    // Runnable as soon as it is spawned.
    Eager
    // Runnable once first awaited or started.
    Lazy
}

// Cancelled is the error `check_cancelled` and `yield_now` return once the current scope has been
// cancelled.
pub type Cancelled = struct {}

// A Scope is the handle a body of `concurrent` starts its tasks through. It is valid only while
// that body runs.
pub type Scope = struct {
    __record: &ScopeRecord
    // The context link every task of the scope runs under.
    __ctx: &u8
    // The start mode `spawn` uses when none is given.
    __start: Start
}

// A Task is a handle to the result of a spawned task. `await` consumes it. A Task that is never
// awaited is reported by W2006, and its result is dropped, unreleased, when the scope ends. A Task
// must not be used after its scope has ended.
pub type Task = struct(T) {
    // Where the task stores its result.
    owned __result: &T
    // The task record holding the task, and that record's generation; the pair stops matching once
    // the record is reused.
    __index: u32
    __gen: u64
}

// The runtime keeps a record for every task and every scope, apart from the handles programs hold.
// Records are reused, never freed. Task records live in one table that moves when it grows, so they
// are named by index and generation, never by address.

// TaskStatus is where a task record is in its life.
type TaskStatus = enum {
    Free
    Lazy
    Started
    Done
}

// TaskRecord is the runtime's record of one task.
type TaskRecord = struct {
    // Incremented each time the record is freed.
    gen: u64
    status: TaskStatus
    // Whether the task's function ended in a panic.
    panicked: bool
    scope: &ScopeRecord?
    // The coroutine running the task, or null before it starts and after it finishes.
    coroutine: &Coroutine?
    // The coroutine blocked in `await` on this task, if any.
    awaiter: &Coroutine?
    // Calls the task's function and stores its result in the slot.
    entry: fn(&u8)
    slot: &u8
    // The context link the task runs under.
    ctx: &u8
    // The next record in the scope's task list while in use, or in the free list.
    next: u32
}

// ScopeRecord is the runtime's record of one open scope. Its arena is kept across uses.
type ScopeRecord = struct {
    job: Job
    // The number of started tasks that have not finished.
    live: usize
    // The coroutine blocked in `join` on this scope, if any.
    joiner: &Coroutine?
    // Whether any task of the scope ended in a panic.
    panicked: bool
    // The first record of the scope's task list.
    tasks: u32
    // Holds the scope's task slots; reset when the scope closes.
    arena: ArenaAllocator
    next_free: &ScopeRecord?
}

// TaskSlot holds a spawned task's function and, once it has run, its result.
type TaskSlot = struct(T) {
    body: fn() T
    result: T
}

// LaunchSlot holds a launched task's function.
type LaunchSlot = struct {
    body: fn()
}

// RootSlot holds the body of an outermost scope and, once it has run, its value.
type RootSlot = struct(R) {
    start: Start
    body: fn(&Scope) R
    result: R
}

// TaskPools holds the task-record table and the free lists of task and scope records. Its memory,
// and that of the scopes' arenas, comes from its own allocator, never from the context's.
type TaskPools = struct {
    tasks: &u8?
    len: u32
    cap: u32
    free_task: u32
    free_scope: &ScopeRecord?
    // The allocator the pools grow from, or null for the heap allocator.
    allocator: &Allocator?
}

const NO_TASK: u32 = 4294967295

const task_pools = TaskPools {
    tasks = null,
    len = 0,
    cap = 0,
    free_task = NO_TASK,
    free_scope = null,
    allocator = null,
}

// Runs `body` with a new scope and returns its value once every task the scope started has
// finished. Called outside any scope, it starts the runtime and blocks the calling thread until
// then; called inside a task, it blocks only that task.
//
// Panics if `body` returns while a task it started is still running, if a task of the scope
// panicked, or if the scope can never finish.
pub fn concurrent(body: fn(&Scope) $R) R {
    return concurrent(Start.Eager, body)
}

// Runs `body` like `concurrent(body)`, with `start` as the scope's default start mode.
pub fn concurrent(start: Start, body: fn(&Scope) $R) R {
    if current_coroutine().is_some() {
        return run_scope(start, body)
    }
    let root: RootSlot(R)
    root.start = start
    root.body = body
    const entry: fn(&u8) = { p: &u8 =>
        const r = p as &RootSlot(R)
        r.result = run_scope(r.start, r.body)
    }
    const c = spawn(entry, &root as &u8)
    run_coroutines()
    if !c.is_done() {
        panic("concurrent: the scope waits on something nothing will ever finish")
    }
    const panicked = c.panicked
    c.deinit()
    if panicked {
        panic("concurrent: a task panicked")
    }
    return move root.result
}

// Starts `body` as a task of the scope, in the scope's default start mode, and returns a handle to
// its result.
pub fn spawn(self: &Scope, body: fn() $T) Task(T) {
    return spawn(self, self.__start, body)
}

// Starts `body` as a task of the scope and returns a handle to its result. An eager task is
// runnable at once. A lazy task starts when first awaited or started, and never runs if neither
// happens before the scope ends.
pub fn spawn(self: &Scope, start: Start, body: fn() $T) Task(T) {
    const entry: fn(&u8) = { p: &u8 =>
        const slot = p as &TaskSlot(T)
        slot.result = slot.body()
    }
    const slot = slot_for(
        self.__record,
        size_of(TaskSlot(T)),
        align_of(TaskSlot(T)),
    ) as &TaskSlot(T)
    slot.body = body
    const i = add_task(self, entry, slot as &u8)
    const gen = task_record(i).gen
    start match {
        Eager => start_task(i)
        Lazy => {}
    }
    return .{ __result = &slot.result, __index = i, __gen = gen }
}

// Starts `body` as a task of the scope that has no result. The task is runnable at once, whatever
// the scope's default start mode; `join` waits for it.
pub fn launch(self: &Scope, body: fn()) {
    const entry: fn(&u8) = { p: &u8 => (p as &LaunchSlot).body() }
    const slot = slot_for(self.__record, size_of(LaunchSlot), align_of(LaunchSlot)) as &LaunchSlot
    slot.body = body
    start_task(add_task(self, entry, slot as &u8))
}

// Starts a lazy task. Does nothing if the task has already started.
//
// Panics if the task's scope has ended.
pub fn start(self: &Task($T)) {
    const r = task_record(self.__index)
    if r.gen != self.__gen {
        panic("start: the task's scope has ended")
    }
    if r.status == TaskStatus.Lazy {
        start_task(self.__index)
    }
}

// Blocks the calling task until the task has finished, then returns its result. A lazy task is
// started first. Returns at once if the task has already finished.
//
// Panics if the task's scope has ended, if called outside every scope, or if the task panicked.
pub fn await(self: move Task($T)) T {
    await_task(self.__index, self.__gen) match {
        0 => {}
        1 => panic("await: the task's scope has ended")
        2 => panic("await: outside a concurrent scope")
        _ => panic("await: the task panicked")
    }
    const r = move self.__result.*
    leak(self)
    return r
}

// Blocks the calling task until every task the scope started has finished. Returns at once if none
// is running.
//
// Panics if called outside every scope, or if a task of the scope panicked.
pub fn join(self: &Scope) {
    const me = current_coroutine() match {
        Some(c) => c
        None => panic("join: outside a concurrent scope")
    }
    const s = self.__record
    loop {
        if s.live == 0 {
            break
        }
        s.joiner = Some(me)
        park()
    }
    if s.panicked {
        panic("join: a task panicked")
    }
}

// Cancels the scope. Its tasks, and every scope nested in them, observe cancellation from then on;
// the scope's parent is not affected.
pub fn cancel(self: &Scope) {
    self.__record.job.cancelled = true
}

// Returns whether the current scope, or any scope enclosing it, has been cancelled. Returns false
// outside every scope.
pub fn is_cancelled() bool {
    let j = context.job
    loop {
        const at = j match {
            Some(x) => x
            None => return false
        }
        if at.cancelled {
            return true
        }
        j = at.parent
    }
}

// Returns `Err(Cancelled)` if the current scope has been cancelled, and `Ok(())` otherwise.
pub fn check_cancelled() Result((), Cancelled) {
    if is_cancelled() {
        return Err(Cancelled {})
    }
    return Ok(())
}

// Suspends the calling task so that every other runnable task runs before it resumes. Returns
// `Err(Cancelled)` without suspending if the current scope is already cancelled, or after resuming
// if it was cancelled meanwhile.
//
// Panics if called outside every scope.
pub fn yield_now() Result((), Cancelled) {
    if is_cancelled() {
        return Err(Cancelled {})
    }
    if current_coroutine().is_none() {
        panic("yield_now: outside a concurrent scope")
    }
    reschedule()
    return check_cancelled()
}

fn run_scope(start: Start, body: fn(&Scope) $R) R {
    const record = acquire_scope(context.job)
    const j: &Job? = Some(&record.job)
    context(job = j) {
        let s = Scope { __record = record, __ctx = context_address(), __start = start }
        const r = body(&s)
        close_scope(record) match {
            0 => {}
            1 => panic("concurrent: the body returned while a task still runs; await or join first")
            _ => panic("concurrent: a task panicked")
        }
        return r
    }
}

fn task_record(i: u32) &TaskRecord {
    return (task_pools.tasks.unwrap() as &TaskRecord) + (i as usize)
}

fn grow_tasks() {
    const cap: u32 = if task_pools.cap == 0 { 64 } else { task_pools.cap * 2 }
    const bytes = (cap as usize) * size_of(TaskRecord)
    const grown = task_pools.tasks match {
        Some(old) => {
            let m = from_raw(old, (task_pools.cap as usize) * size_of(TaskRecord))
            if !realloc(pools_allocator(), &m, bytes) {
                panic("out of memory growing the task table")
            }
            move m
        }
        None => alloc(pools_allocator(), bytes, align_of(TaskRecord)) match {
            Some(m) => move m
            None => panic("out of memory growing the task table")
        }
    }
    const base: &u8 = grown.ptr
    task_pools.tasks = Some(base)
    task_pools.cap = cap
    leak(grown)
}

fn acquire_task() u32 {
    if task_pools.free_task != NO_TASK {
        const i = task_pools.free_task
        task_pools.free_task = task_record(i).next
        return i
    }
    if task_pools.len == task_pools.cap {
        grow_tasks()
    }
    const i = task_pools.len
    task_pools.len = task_pools.len + 1
    task_record(i).gen = 0
    return i
}

fn release_task(i: u32) {
    const r = task_record(i)
    r.status = TaskStatus.Free
    r.gen = r.gen + 1
    r.scope = null
    r.coroutine = null
    r.awaiter = null
    r.next = task_pools.free_task
    task_pools.free_task = i
}

fn add_task(scope: &Scope, entry: fn(&u8), slot: &u8) u32 {
    const i = acquire_task()
    const r = task_record(i)
    r.status = TaskStatus.Lazy
    r.panicked = false
    r.scope = Some(scope.__record)
    r.coroutine = null
    r.awaiter = null
    r.entry = entry
    r.slot = slot
    r.ctx = scope.__ctx
    r.next = scope.__record.tasks
    scope.__record.tasks = i
    return i
}

fn start_task(i: u32) {
    const r = task_record(i)
    r.status = TaskStatus.Started
    const c = __spawn_in(r.entry, r.slot, r.ctx, task_done, i as u64)
    r.coroutine = Some(c)
    const s = r.scope.unwrap()
    s.live = s.live + 1
}

fn task_done(c: &Coroutine) {
    const r = task_record(c.tag as u32)
    r.status = TaskStatus.Done
    r.panicked = c.panicked
    r.coroutine = null
    c.deinit()
    const s = r.scope.unwrap()
    if r.panicked {
        s.panicked = true
    }
    s.live = s.live - 1
    if s.live == 0 {
        s.joiner match {
            Some(j) => {
                s.joiner = null
                j.wake()
            }
            None => {}
        }
    }
    r.awaiter match {
        Some(a) => a.wake()
        None => {}
    }
}

// Returns 0 once the task has finished, 1 if the handle outlived its scope, 2 outside every scope,
// and 3 if the task panicked.
fn await_task(i: u32, gen: u64) i32 {
    if task_record(i).gen != gen {
        return 1
    }
    const me = current_coroutine() match {
        Some(c) => c
        None => return 2
    }
    if task_record(i).status == TaskStatus.Lazy {
        start_task(i)
    }
    loop {
        if task_record(i).status == TaskStatus.Done {
            break
        }
        task_record(i).awaiter = Some(me)
        park()
    }
    const r = task_record(i)
    r.awaiter = null
    return if r.panicked { 3 } else { 0 }
}

fn ignore_done(c: &Coroutine) {}

fn pools_allocator() &Allocator {
    return task_pools.allocator match {
        Some(a) => a
        None => heap_allocator()
    }
}

fn slot_for(s: &ScopeRecord, size: usize, align: usize) &u8 {
    let a = allocator(&s.arena)
    const m = alloc(&a, size, align) match {
        Some(m) => move m
        None => panic("out of memory for a task")
    }
    const p = m.ptr
    leak(m)
    return p
}

fn acquire_scope(parent: &Job?) &ScopeRecord {
    const s = task_pools.free_scope match {
        Some(f) => {
            task_pools.free_scope = f.next_free
            f
        }
        None => box(
            pools_allocator(),
            ScopeRecord {
                job = Job { parent = null, cancelled = false },
                live = 0,
                joiner = null,
                panicked = false,
                tasks = NO_TASK,
                arena = arena_allocator(pools_allocator()),
                next_free = null,
            },
        )
    }
    s.job.parent = parent
    s.job.cancelled = false
    s.live = 0
    s.joiner = null
    s.panicked = false
    s.tasks = NO_TASK
    s.next_free = null
    return s
}

// Returns 1, leaving the scope open, if a started task is still running. Otherwise drops the
// unstarted tasks, frees every record and the scope for reuse, and returns 3 if a task panicked or
// 0 if none did.
fn close_scope(s: &ScopeRecord) i32 {
    if s.live > 0 {
        return 1
    }
    const panicked = s.panicked
    let i = s.tasks
    loop {
        if i == NO_TASK {
            break
        }
        const next = task_record(i).next
        release_task(i)
        i = next
    }
    reset(&s.arena)
    s.next_free = task_pools.free_scope
    task_pools.free_scope = Some(s)
    return if panicked { 3 } else { 0 }
}

fn __task_test_add(a: i32, b: i32) i32 {
    return a + b
}

fn __task_test_spin(rounds: &i32) i32 {
    loop {
        if yield_now().is_err() {
            return rounds.*
        }
        rounds.* = rounds.* + 1
    }
}

fn __task_test_mark(flag: &bool) i32 {
    flag.* = true
    return 1
}

fn __task_test_noop() {}

fn __task_test_launch_many(n: usize) usize {
    return concurrent { s =>
        for _i in 0..n {
            s.launch { __task_test_noop() }
        }
        s.join()
        n
    }
}

test "spawned tasks hand their results back through await" {
    const sum = concurrent { s =>
        const a = s.spawn { __task_test_add(1, 2) }
        const b = s.spawn { __task_test_add(3, 4) }
        a.await() + b.await()
    }
    assert_eq(sum, 10, "sum")
}

test "a cancelled scope's task stops at its next check" {
    let rounds = 0
    const seen = concurrent { s =>
        const spinner = s.spawn { __task_test_spin(&rounds) }
        for _i in 0usize..3usize {
            let _y = yield_now()
        }
        s.cancel()
        spinner.await()
    }
    assert_true(seen >= 1, "the spinner ran before the cancel")
    assert_true(!is_cancelled(), "the caller's scope is untouched")
}

test "a lazy task never awaited does not run" {
    let ran = false
    const before = concurrent(Start.Lazy) { s =>
        let _t = s.spawn { __task_test_mark(&ran) }
        ran
    }
    assert_true(!before and !ran, "dropped unstarted")
}

test "a repeated scope allocates nothing once the pools are warm" {
    let _warm = __task_test_launch_many(100)
    let counter = counting_allocator(heap_allocator())
    let counted = allocator(&counter)
    task_pools.allocator = Some(&counted)
    let _again = __task_test_launch_many(100)
    task_pools.allocator = null
    assert_eq(counter.allocs + counter.reallocs, 0, "no allocation through the pools")
}
