// std.task runs concurrent work as tasks inside scopes (RFC-005).
//
// `concurrent` opens a scope: it runs a body with the scope and returns the body's value once every
// task the scope started has finished. Inside the body, `spawn` starts a task and returns a `Task`,
// whose `await` yields the task's result; `launch` starts a task that has no result, and `join`
// waits for every task the scope started. Called outside any scope, `concurrent` starts the runtime
// and blocks the calling thread; called inside a task, it opens a nested scope and blocks only that
// task.
//
// `select` waits for the first of several operations: tasks finishing and channel operations.
// `race` returns the result of the first of several tasks to finish, and `any` the first success;
// both cancel the rest.
//
// Cancellation is cooperative. `cancel` cancels a scope's tasks and every scope nested in them,
// never the scope's parent; on a task, it cancels that task alone. A task observes cancellation
// only by asking its job, through `context.job.is_cancelled()` or `context.job.check_cancelled()`,
// or by suspending, as `yield_now` and channel operations do. Nothing interrupts a task, so it
// returns normally and its deferred calls run.
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
import std.collections.list
import std.option
import std.result
import std.runtime.coro
import std.test

// A Job is a scope's cancellation state. A job counts as cancelled when it, or any job above it, is
// cancelled.
pub type Job = struct {
    // The job of the enclosing scope, or null for the background job.
    parent: &Job?
    cancelled: bool
}

// background is the job outside every scope. It is never cancelled.
const background = Job { parent = null, cancelled = false }

// job is the job of the innermost scope the current code runs in, or the background job outside
// every scope.
pub context job: &Job = &background

// Start says when a spawned task begins running.
pub type Start = enum {
    // Runnable as soon as it is spawned.
    Eager
    // Runnable once first awaited or started.
    Lazy
}

// Cancelled is the error a job's `check_cancelled`, `yield_now` and channel operations return once
// the current scope has been cancelled.
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
    // The job the task runs under: its own for a spawned task, its scope's for a launched one.
    job: &Job
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
    // The coroutine running the scope's body.
    opener: &Coroutine?
    // The next scope in the list of open scopes.
    next_open: &ScopeRecord?
    next_free: &ScopeRecord?
}

// TaskSlot holds a spawned task's job and function and, once it has run, its result.
type TaskSlot = struct(T) {
    job: Job
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
    // Every open scope, so that a cancellation can reach the coroutines waiting in them.
    open_scopes: &ScopeRecord?
    free_arenas: &ArmArena?
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
    open_scopes = null,
    free_arenas = null,
    allocator = null,
}

// Runs `body` with a new scope and returns its value once every task the scope started has
// finished. Called outside any scope, it starts the runtime and blocks the calling thread until
// then; called inside a task, it blocks only that task.
//
// Panics if `body` returns while a task it started is still running, if a task of the scope
// panicked, or if the scope can never finish.
pub fn concurrent(#it(scope) body: fn(&Scope) $R) R {
    return concurrent(Start.Eager, body)
}

// Runs `body` like `concurrent(body)`, with `start` as the scope's default start mode.
pub fn concurrent(start: Start, #it(scope) body: fn(&Scope) $R) R {
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
        context(job = &slot.job) {
            slot.result = slot.body()
        }
    }
    const slot = arena_slot(
        &self.__record.arena,
        size_of(TaskSlot(T)),
        align_of(TaskSlot(T)),
    ) as &TaskSlot(T)
    slot.job = Job { parent = Some(&self.__record.job), cancelled = false }
    slot.body = body
    const i = add_task(self, &slot.job, entry, slot as &u8)
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
    const slot = arena_slot(
        &self.__record.arena,
        size_of(LaunchSlot),
        align_of(LaunchSlot),
    ) as &LaunchSlot
    slot.body = body
    start_task(add_task(self, &self.__record.job, entry, slot as &u8))
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
// a task waiting in a channel operation stops waiting. The scope's parent is not affected.
pub fn cancel(self: &Scope) {
    self.__record.job.cancelled = true
    wake_cancelled()
}

// Cancels the task. It, and every scope nested in it, observe cancellation from then on; the rest
// of its scope is not affected. Does nothing if the task has finished.
//
// Panics if the task's scope has ended.
pub fn cancel(self: &Task($T)) {
    const r = task_record(self.__index)
    if r.gen != self.__gen {
        panic("cancel: the task's scope has ended")
    }
    r.job.cancelled = true
    wake_cancelled()
}

// Returns whether the job, or any job above it, has been cancelled.
pub fn is_cancelled(self: &Job) bool {
    let j: &Job? = Some(self)
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

// Returns `Err(Cancelled)` if the job, or any job above it, has been cancelled, and `Ok(())`
// otherwise.
pub fn check_cancelled(self: &Job) Result((), Cancelled) {
    if self.is_cancelled() {
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
    if context.job.is_cancelled() {
        return Err(Cancelled {})
    }
    if current_coroutine().is_none() {
        panic("yield_now: outside a concurrent scope")
    }
    reschedule()
    return context.job.check_cancelled()
}

// A Selector is the handle a body of `select` registers its arms through. It is valid only while
// that body runs.
pub type Selector = struct(R) {
    __select: &Select
    // Where the winning arm's handler stores the select's value.
    __result: &R
}

// ArmOps is what a select does with one kind of arm. Each operation takes the arm's record.
pub type ArmOps = struct {
    // Whether the operation has completed on its own, as a task finishing does.
    done: fn(&u8) bool
    // Whether the operation reports the scope's cancellation, so that the arm can win by it.
    cancels: bool
    // The arm lost: leaves every queue it waits in and releases what it holds.
    withdraw: fn(&u8)
    // The arm won: leaves every queue it waits in and runs its handler. The flag says whether it
    // won by the scope's cancellation.
    finish: fn(&u8, bool)
}

// An Arm is an operation a select waits on. A counterpart that completes the operation calls
// `__win` first, and completes it only if that returns true.
pub type Arm = struct {
    __record: &u8
    __ops: ArmOps
    __select: &Select
    __next: &Arm?
}

// Select is a select in progress.
type Select = struct {
    // The arms that wait, in registration order.
    arms: &Arm?
    last: &Arm?
    won: &Arm?
    // Whether an arm completed while the body ran, its handler already run.
    decided: bool
    // Whether the body has called `wait`.
    waited: bool
    // Whether the winner won by the scope's cancellation.
    cancelled: bool
    arena: &ArmArena
}

// ArmArena holds a select's arm records. Arenas are reused across selects.
type ArmArena = struct {
    arena: ArenaAllocator
    next: &ArmArena?
}

// Runs `body`, which registers arms with `on(op) { ... }` and ends with `on.wait()`, and returns
// the value the handler of the one arm whose operation completes first returns. Arms are tried in
// order as they register: the first whose operation can complete at once wins, its handler runs,
// and later arms are dropped unperformed. If none can, `wait` blocks the calling task until one
// completes, then runs that arm's handler. Every other operation is withdrawn without taking
// effect; a send that loses releases its value.
//
// Once the current scope is cancelled, the first channel arm completes with a cancellation error. A
// select whose arms are all tasks keeps waiting, as `await` does.
//
// Panics if `body` returns without calling `wait`, if it registers no arm, or if an arm that cannot
// complete at once registers outside every scope.
pub fn select(#it(on) body: fn(&Selector($R))) R {
    let result: R
    let state = Select {
        arms = null,
        last = null,
        won = null,
        decided = false,
        waited = false,
        cancelled = false,
        arena = acquire_arm_arena(),
    }
    let sel = Selector(R) { __select = &state, __result = &result }
    body(&sel)
    if !state.waited {
        state.won = null
        state.withdraw_losers()
        release_arm_arena(state.arena)
        panic("select: the body returned without calling `wait`")
    }
    release_arm_arena(state.arena)
    return move result
}

// Blocks the calling task until an arm of the select has won, unless one already has, then
// withdraws the other arms and runs the winner's handler. The body of `select` ends with it: a
// handler may refer to the body's locals, which live only until the body returns.
//
// Panics if no arm was registered, or if `wait` was already called, from the body or a handler.
pub fn wait(self: &Selector($R)) {
    if self.__select.waited {
        panic("select: `wait` called twice")
    }
    self.__select.finish()
}

// Registers a select arm that wins once the task has finished. A lazy task is started. The handler
// takes no argument; `await` the task for its result.
//
// Panics if the task's scope has ended.
pub fn op_call(self: &Selector($R), task: &Task($T), handler: move $F) where F: fn() R {
    if self.__won() {
        release(handler)
        return
    }
    const r = task_record(task.__index)
    if r.gen != task.__gen {
        panic("select: the task's scope has ended")
    }
    if r.status == TaskStatus.Lazy {
        start_task(task.__index)
    }
    if r.status == TaskStatus.Done {
        self.__decide(handler())
        return
    }
    const ops = ArmOps {
        done = { p: &u8 => (p as &TaskArm(F, R)).done() },
        cancels = false,
        withdraw = { p: &u8 => (p as &TaskArm(F, R)).withdraw() },
        finish = { p: &u8, cancelled: bool => (p as &TaskArm(F, R)).finish() },
    }
    const a = self.__wait(
        size_of(TaskArm(F, R)),
        align_of(TaskArm(F, R)),
        ops,
    ).__record as &TaskArm(F, R)
    a.index = task.__index
    a.handler = move handler
    a.out = self.__result
    r.awaiter = current_coroutine()
}

// Returns whether an arm of the select has already won.
//
// Panics after `wait`: every arm registers before it.
pub fn __won(self: &Selector($R)) bool {
    if self.__select.waited {
        panic("select: an arm registered after `wait`")
    }
    return self.__select.won.is_some() or self.__select.decided
}

// Makes `value` the select's value, for an arm that completed while the body runs.
pub fn __decide(self: &Selector($R), value: move R) {
    self.__select.decided = true
    self.__result.* = move value
}

// Adds an arm that waits, with a record of `size` bytes at `align` and the operations `ops`, and
// returns it. The record is valid until the select returns.
//
// Panics outside every scope.
pub fn __wait(self: &Selector($R), size: usize, align: usize, ops: ArmOps) &Arm {
    if current_coroutine().is_none() {
        panic("select: outside a concurrent scope")
    }
    const s = self.__select
    let a = allocator(&s.arena.arena)
    const arm = box(
        &a,
        Arm {
            __record = arena_slot(&s.arena.arena, size, align),
            __ops = ops,
            __select = s,
            __next = null,
        },
    )
    s.last match {
        Some(l) => l.__next = Some(arm)
        None => s.arms = Some(arm)
    }
    s.last = Some(arm)
    return arm
}

// Makes the arm the select's winner. Returns false if another arm has already won.
pub fn __win(self: &Arm) bool {
    const s = self.__select
    if s.won.is_some() or s.decided {
        return false
    }
    s.won = Some(self)
    return true
}

// TaskArm is a select's arm waiting for a task to finish.
type TaskArm = struct(F, R) {
    index: u32
    handler: F
    out: &R
}

fn done(self: &TaskArm($F, $R)) bool {
    return task_record(self.index).status == TaskStatus.Done
}

fn withdraw(self: &TaskArm($F, $R)) {
    task_record(self.index).awaiter = null
}

fn finish(self: &TaskArm($F, $R)) where F: fn() R {
    task_record(self.index).awaiter = null
    self.out.* = self.handler()
}

// Waits for a winner unless the body decided the select, then withdraws every other arm and
// finishes the winner.
fn finish(self: &Select) {
    self.waited = true
    if !self.decided {
        self.await_winner()
    }
    self.withdraw_losers()
    self.won match {
        Some(w) => w.finish()
        None => {}
    }
}

fn withdraw_losers(self: &Select) {
    let at = self.arms
    loop {
        const a = at ?? break
        if !self.won_by(a) {
            a.withdraw()
        }
        at = a.__next
    }
}

// Blocks until an arm wins: one a counterpart completes, one whose operation completes on its own,
// or, once the current scope is cancelled, the first that reports cancellation.
fn await_winner(self: &Select) {
    if self.arms.is_none() {
        panic("select: no arms")
    }
    loop {
        if self.won.is_some() or (self.win_first { it.done() }) {
            return
        }
        if context.job.is_cancelled() and (self.win_first { it.__ops.cancels }) {
            self.cancelled = true
            return
        }
        park()
    }
}

// Makes the first arm, in registration order, for which `pred` holds the winner, and returns
// whether there was one.
fn win_first(self: &Select, pred: fn(&Arm) bool) bool {
    let at = self.arms
    loop {
        const a = at ?? return false
        if pred(a) {
            self.won = Some(a)
            return true
        }
        at = a.__next
    }
}

#allow(W2004)
fn won_by(self: &Select, a: &Arm) bool {
    return self.won match {
        Some(w) => (w as usize) == (a as usize)
        None => false
    }
}

fn done(self: &Arm) bool {
    return self.__ops.done(self.__record)
}

fn withdraw(self: &Arm) {
    self.__ops.withdraw(self.__record)
}

fn finish(self: &Arm) {
    self.__ops.finish(self.__record, self.__select.cancelled)
}

fn acquire_arm_arena() &ArmArena {
    return task_pools.free_arenas match {
        Some(a) => {
            task_pools.free_arenas = a.next
            a
        }
        None => box(
            pools_allocator(),
            ArmArena { arena = arena_allocator(pools_allocator()), next = null },
        )
    }
}

fn release_arm_arena(a: &ArmArena) {
    reset(&a.arena)
    a.next = task_pools.free_arenas
    task_pools.free_arenas = Some(a)
}

// Returns the result of the first of `tasks` to finish, then cancels the others and waits for them,
// releasing their results. Lazy tasks are started.
//
// Panics if `tasks` is empty, if called outside every scope, if a task's scope has ended, or if the
// winning task panicked.
pub fn race(tasks: move List(Task($T))) T {
    const i = first_done(&tasks)
    const winner = tasks.remove_at(i).unwrap()
    cancel_rest(tasks)
    return winner.await()
}

// Runs `first` and `second` as tasks of a new scope and returns the result of the one that finishes
// first. The other is cancelled; its result is released once it returns.
pub fn race(first: fn() $T, second: fn() T) T {
    return concurrent {
        let tasks = list(2)
        tasks.push(scope.spawn(Start.Eager, first))
        tasks.push(scope.spawn(Start.Eager, second))
        race(tasks)
    }
}

// Returns the first `Ok` result of `tasks`, in the order they finish, then cancels the others and
// waits for them, releasing their results. If every task fails, returns the error of the last to
// finish and releases the others. Lazy tasks are started.
//
// Panics if `tasks` is empty, if called outside every scope, if a task's scope has ended, or if an
// awaited task panicked.
pub fn any(tasks: move List(Task(Result($T, $E)))) Result(T, E) {
    loop {
        const i = first_done(&tasks)
        const r = tasks.remove_at(i).unwrap().await()
        if tasks.len == 0 {
            free_tasks(tasks)
            return r
        }
        r match {
            Ok(v) => {
                cancel_rest(tasks)
                return Ok(move v)
            }
            Err(e) => release(e)
        }
    }
}

// Returns the position of the first of `tasks` found finished, starting the lazy ones and blocking
// the calling task until one finishes.
fn first_done(tasks: &List(Task($T))) usize {
    if tasks.len == 0 {
        panic("race: no tasks")
    }
    const me = current_coroutine() ?? panic("race: outside a concurrent scope")
    for &t in tasks {
        const r = task_record(t.__index)
        if r.gen != t.__gen {
            panic("race: a task's scope has ended")
        }
        if r.status == TaskStatus.Lazy {
            start_task(t.__index)
        }
    }
    loop {
        const i = done_index(tasks)
        if i.is_some() {
            for &t in tasks {
                task_record(t.__index).awaiter = null
            }
            return i.unwrap()
        }
        for &t in tasks {
            task_record(t.__index).awaiter = Some(me)
        }
        park()
    }
}

fn done_index(tasks: &List(Task($T))) usize? {
    let i = 0usize
    for &t in tasks {
        if task_record(t.__index).status == TaskStatus.Done {
            return Some(i)
        }
        i = i + 1
    }
    return null
}

// Cancels every task, then waits for each and releases its result.
fn cancel_rest(tasks: move List(Task($T))) {
    for &t in tasks {
        t.cancel()
    }
    for t in tasks.drain() {
        release(t.await())
    }
    free_tasks(tasks)
}

// Frees an emptied list of tasks. `Task` declares no `deinit`, so the list's own cannot be called.
fn free_tasks(tasks: move List(Task($T))) {
    let _empty = tasks.to_owned_slice()
    leak(tasks)
}

fn run_scope(start: Start, body: fn(&Scope) $R) R {
    const record = acquire_scope(context.job)
    context(job = &record.job) {
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

fn add_task(scope: &Scope, job: &Job, entry: fn(&u8), slot: &u8) u32 {
    const i = acquire_task()
    const r = task_record(i)
    r.status = TaskStatus.Lazy
    r.job = job
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

// Wakes every coroutine of an open scope whose job is now cancelled: the one running the scope's
// body if the scope's job is, and each task whose own job is. A coroutine woken without cause goes
// back to waiting.
fn wake_cancelled() {
    let at = task_pools.open_scopes
    loop {
        const s = at match {
            Some(s) => s
            None => break
        }
        if s.job.is_cancelled() {
            s.opener match {
                Some(c) => c.wake()
                None => {}
            }
        }
        let i = s.tasks
        loop {
            if i == NO_TASK {
                break
            }
            const r = task_record(i)
            if r.job.is_cancelled() {
                r.coroutine match {
                    Some(c) => c.wake()
                    None => {}
                }
            }
            i = r.next
        }
        at = s.next_open
    }
}

#allow(W2004)
fn same_scope(a: &ScopeRecord, b: &ScopeRecord) bool {
    return (a as usize) == (b as usize)
}

fn remove_open_scope(s: &ScopeRecord) {
    const head = task_pools.open_scopes match {
        Some(h) => h
        None => return
    }
    if same_scope(head, s) {
        task_pools.open_scopes = s.next_open
        return
    }
    let at = head
    loop {
        const n = at.next_open match {
            Some(n) => n
            None => return
        }
        if same_scope(n, s) {
            at.next_open = s.next_open
            return
        }
        at = n
    }
}

fn pools_allocator() &Allocator {
    return task_pools.allocator match {
        Some(a) => a
        None => heap_allocator()
    }
}

fn arena_slot(arena: &ArenaAllocator, size: usize, align: usize) &u8 {
    let a = allocator(arena)
    const m = alloc(&a, size, align) match {
        Some(m) => move m
        None => panic("out of memory for a task")
    }
    const p = m.ptr
    leak(m)
    return p
}

fn acquire_scope(parent: &Job) &ScopeRecord {
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
                opener = null,
                next_open = null,
                next_free = null,
            },
        )
    }
    s.job.parent = Some(parent)
    s.job.cancelled = false
    s.live = 0
    s.joiner = null
    s.panicked = false
    s.tasks = NO_TASK
    s.opener = current_coroutine()
    s.next_open = task_pools.open_scopes
    task_pools.open_scopes = Some(s)
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
    remove_open_scope(s)
    s.opener = null
    s.next_free = task_pools.free_scope
    task_pools.free_scope = Some(s)
    return if panicked { 3 } else { 0 }
}

fn __task_test_add(a: i32, b: i32) i32 {
    return a + b
}

fn __task_test_spin(rounds: &i32) i32 {
    loop {
        yield_now() ?? return rounds.*
        rounds.* = rounds.* + 1
    }
}

fn __task_test_mark(flag: &bool) i32 {
    flag.* = true
    return 1
}

fn __task_test_noop() {}

fn __task_test_launch_many(n: usize) usize {
    return concurrent {
        for _i in 0..n {
            scope.launch { __task_test_noop() }
        }
        scope.join()
        n
    }
}

test "spawned tasks hand their results back through await" {
    const sum = concurrent {
        const a = scope.spawn { __task_test_add(1, 2) }
        const b = scope.spawn { __task_test_add(3, 4) }
        a.await() + b.await()
    }
    assert_eq(sum, 10, "sum")
}

test "a cancelled scope's task stops at its next check" {
    let rounds = 0
    const seen = concurrent {
        const spinner = scope.spawn { __task_test_spin(&rounds) }
        for _i in 0usize..3usize {
            let _y = yield_now()
        }
        scope.cancel()
        spinner.await()
    }
    assert_true(seen >= 1, "the spinner ran before the cancel")
    assert_true(!context.job.is_cancelled(), "the caller's scope is untouched")
}

test "a lazy task never awaited does not run" {
    let ran = false
    const before = concurrent(Start.Lazy) {
        const t = scope.spawn { __task_test_mark(&ran) }
        leak(t)
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

fn __task_test_after(rounds: i32, v: i32) i32 {
    for _i in 0..rounds {
        let _y = yield_now()
    }
    return v
}

fn __task_test_fail_after(rounds: i32, v: i32) Result(i32, i32) {
    for _i in 0..rounds {
        let _y = yield_now()
    }
    return Err(v)
}

fn __task_test_ok_after(rounds: i32, v: i32) Result(i32, i32) {
    for _i in 0..rounds {
        let _y = yield_now()
    }
    return Ok(v)
}

test "select over tasks wins on the first to finish" {
    const got = concurrent {
        const slow = scope.spawn { __task_test_after(5, 1) }
        const fast = scope.spawn { __task_test_after(1, 2) }
        const which = select {
            on(&slow) { 10 }
            on(&fast) { 20 }
            on.wait()
        }
        which + slow.await() + fast.await()
    }
    assert_eq(got, 23, "fast won; both still awaitable")
}

test "cancelling a task leaves its siblings running" {
    let rounds = 0
    const got = concurrent {
        const spinner = scope.spawn { __task_test_spin(&rounds) }
        const other = scope.spawn { __task_test_after(3, 7) }
        let _y = yield_now()
        spinner.cancel()
        let _seen = spinner.await()
        other.await()
    }
    assert_eq(got, 7, "the sibling finished")
}

test "race returns the first result and cancels the rest" {
    let rounds = 0
    const got = concurrent {
        let tasks = list(2)
        tasks.push(scope.spawn { __task_test_spin(&rounds) })
        tasks.push(scope.spawn { __task_test_after(2, 42) })
        race(tasks)
    }
    assert_eq(got, 42, "the finite task won; the spinner stopped")
}

test "race over two functions" {
    const got = concurrent {
        race({ __task_test_after(4, 1) }, { __task_test_after(1, 2) })
    }
    assert_eq(got, 2, "the faster one")
}

test "any skips failures and returns the first success" {
    const got = concurrent {
        let tasks = list(3)
        tasks.push(scope.spawn { __task_test_fail_after(1, 1) })
        tasks.push(scope.spawn { __task_test_ok_after(3, 5) })
        tasks.push(scope.spawn { __task_test_ok_after(6, 9) })
        any(tasks)
    }
    assert_true(got.is_ok() and got.unwrap() == 5, "the first Ok")
}

test "any returns the last error when every task fails" {
    const got = concurrent {
        let tasks = list(2)
        tasks.push(scope.spawn { __task_test_fail_after(1, 1) })
        tasks.push(scope.spawn { __task_test_fail_after(3, 2) })
        any(tasks)
    }
    assert_true(got.is_err() and got.unwrap_err() == 2, "the last to fail")
}
