// std.runtime.coro implements stackful coroutines on a single worker thread. It is the runtime
// beneath std.task; programs use std.task, not this module.
//
// A coroutine is a function running on a stack of its own. `spawn` creates one runnable; it runs
// only while a thread is inside `run_coroutines`, which resumes runnable coroutines in the order
// they became runnable and returns when none is left. A running coroutine keeps the thread until it
// returns, calls `reschedule` to let the others run first, or calls `park` to wait for a `wake`.
//
// A coroutine's stack is 1 MiB, reserved when the coroutine is created and committed by the
// operating system as it is touched. It never grows or moves; overflowing it faults on a guard page
// and ends the process. A finished coroutine is handed back with `deinit` and reused, stack
// included.

import std.allocator
import std.option
import std.test

// Machine is a stack and the saved registers that resume it. Machines are created and switched by
// the C half of the runtime; they are reused, never freed.
type Machine = #foreign struct {}

#foreign fn __flang_machine_thread() &Machine
#foreign fn __flang_machine_new(stack_size: usize) &Machine
#foreign fn __flang_machine_prepare(m: &Machine, entry: &u8, arg: &u8, ctx: &u8)
#foreign fn __flang_machine_switch(from: &Machine, to: &Machine)
#foreign fn __flang_machine_finished(m: &Machine) i32

// CoroutineState is where a coroutine is in its life.
type CoroutineState = enum {
    Runnable
    Running
    Parked
    Done
}

// A Coroutine is a function running on its own stack, with its scheduling state. The spawner holds
// it until it is done and then hands it back with `deinit`; it must not be used after that.
pub type Coroutine = struct {
    machine: &Machine
    state: CoroutineState
    // Set by a `wake` that found the coroutine not parked; consumed by its next `park`.
    wake_pending: bool
    // Whether the function ended in a panic instead of returning. Meaningful once the coroutine is
    // done.
    panicked: bool
    // The next coroutine in the run queue or in the free list.
    next: &Coroutine?
    // Called by `run_coroutines`, on the thread's own stack, once the coroutine is done.
    on_done: fn(&Coroutine)
    // A value for `on_done` to read, set at spawn.
    tag: u64
}

// Scheduler is the state of the one worker. `head` and `tail` bound the run queue; `current` is the
// running coroutine, null while `run_coroutines` itself executes; `free` lists finished coroutines
// kept for reuse.
type Scheduler = struct {
    head: &Coroutine?
    tail: &Coroutine?
    current: &Coroutine?
    free: &Coroutine?
    // The allocator coroutines come from, or null for the heap allocator.
    allocator: &Allocator?
}

const scheduler = Scheduler {
    head = null,
    tail = null,
    current = null,
    free = null,
    allocator = null,
}

// Spawns a coroutine that calls `entry(arg)` under the caller's context, and returns it. The
// coroutine is runnable but starts only once a thread enters `run_coroutines`.
//
// `arg`, everything it refers to and the caller's context must remain valid until the coroutine is
// done.
pub fn spawn(entry: fn(&u8), arg: &u8) &Coroutine {
    return __spawn_in(entry, arg, context_address(), ignore_done, 0)
}

// Spawns a coroutine like `spawn(entry, arg)`. When the coroutine is done, `run_coroutines` calls
// `on_done` with it, on the thread's own stack; `tag` is stored in the coroutine for `on_done` to
// read.
pub fn spawn(entry: fn(&u8), arg: &u8, on_done: fn(&Coroutine), tag: u64) &Coroutine {
    return __spawn_in(entry, arg, context_address(), on_done, tag)
}

// Spawns a coroutine like `spawn(entry, arg, on_done, tag)`, but running `entry(arg)` under the
// context link at `ctx`. For the standard library only: a link comes from `context_address`, which
// other modules cannot call.
//
// `ctx` must remain valid until the coroutine is done.
pub fn __spawn_in(entry: fn(&u8), arg: &u8, ctx: &u8, on_done: fn(&Coroutine), tag: u64) &Coroutine {
    const c = acquire()
    c.on_done = on_done
    c.tag = tag
    __flang_machine_prepare(c.machine, &entry as &u8, arg, ctx)
    enqueue(c)
    return c
}

// Runs coroutines on the calling thread until none is runnable, then returns. A coroutine still
// parked when it returns stays parked; a later `wake` makes it runnable for the next call.
//
// Panics if called from inside a coroutine.
pub fn run_coroutines() {
    if scheduler.current.is_some() {
        panic("run_coroutines: inside a coroutine")
    }
    const thread = __flang_machine_thread()
    loop {
        const c = dequeue() match {
            Some(c) => c
            None => break
        }
        c.state = CoroutineState.Running
        scheduler.current = Some(c)
        __flang_machine_switch(thread, c.machine)
        scheduler.current = null
        const finished = __flang_machine_finished(c.machine)
        if finished != 0 {
            c.state = CoroutineState.Done
            c.panicked = finished == 2
            const done = c.on_done
            done(c)
        }
    }
}

// Suspends the calling coroutine and makes it runnable again at once, so every coroutine already
// runnable runs before it resumes.
//
// Panics if called outside a coroutine.
pub fn reschedule() {
    const c = require_current("reschedule: outside a coroutine")
    enqueue(c)
    suspend(c)
}

// Suspends the calling coroutine until `wake` is called on it. If a wake arrived since the last
// park, park consumes it and returns at once.
//
// Panics if called outside a coroutine.
pub fn park() {
    const c = require_current("park: outside a coroutine")
    if c.wake_pending {
        c.wake_pending = false
        return
    }
    c.state = CoroutineState.Parked
    suspend(c)
}

// Makes a parked coroutine runnable. A wake for a coroutine that is not parked is kept, and its
// next `park` returns at once; a wake for a coroutine that is done does nothing.
pub fn wake(self: &Coroutine) {
    self.state match {
        Parked => enqueue(self)
        Done => {}
        _ => self.wake_pending = true
    }
}

// Returns the running coroutine, or null outside a coroutine.
pub fn current_coroutine() &Coroutine? {
    return scheduler.current
}

// Returns whether the coroutine has finished.
pub fn is_done(self: &Coroutine) bool {
    return self.state == CoroutineState.Done
}

// Hands a finished coroutine back for reuse. The coroutine must not be used afterwards.
//
// Panics if the coroutine has not finished.
pub fn deinit(self: &Coroutine) {
    if self.state != CoroutineState.Done {
        panic("coroutine freed before it finished")
    }
    self.next = scheduler.free
    scheduler.free = Some(self)
}

// Returns the address of the context link the caller runs under, so that a function can run under
// it on another stack. The address is valid until the caller returns.
//
// Only standard-library modules may call it (E2149 elsewhere), and only directly: the compiler
// supplies the result at the call site.
//
// Panics if reached through a function value.
#intrinsic
pub fn context_address() &u8 {
    panic("context_address answers only a direct call")
}

fn acquire() &Coroutine {
    const c = scheduler.free match {
        Some(f) => {
            scheduler.free = f.next
            f
        }
        None => box(
            scheduler_allocator(),
            Coroutine {
                machine = __flang_machine_new(0),
                state = CoroutineState.Done,
                wake_pending = false,
                panicked = false,
                next = null,
                on_done = ignore_done,
                tag = 0,
            },
        )
    }
    c.wake_pending = false
    c.panicked = false
    c.next = null
    c.on_done = ignore_done
    c.tag = 0
    return c
}

fn ignore_done(c: &Coroutine) {}

fn scheduler_allocator() &Allocator {
    return scheduler.allocator match {
        Some(a) => a
        None => heap_allocator()
    }
}

fn enqueue(c: &Coroutine) {
    c.state = CoroutineState.Runnable
    c.next = null
    scheduler.tail match {
        Some(t) => t.next = Some(c)
        None => scheduler.head = Some(c)
    }
    scheduler.tail = Some(c)
}

fn dequeue() &Coroutine? {
    const c = scheduler.head match {
        Some(h) => h
        None => return null
    }
    scheduler.head = c.next
    if scheduler.head.is_none() {
        scheduler.tail = null
    }
    c.next = null
    return Some(c)
}

fn require_current(msg: String) &Coroutine {
    return scheduler.current match {
        Some(c) => c
        None => panic(msg)
    }
}

fn suspend(c: &Coroutine) {
    __flang_machine_switch(c.machine, __flang_machine_thread())
}

// Trace records the order in which test coroutines reach their marks.
type Trace = struct {
    steps: [i32; 8]
    len: usize
}

fn record(t: &Trace, v: i32) {
    t.steps[t.len] = v
    t.len = t.len + 1
}

// Step is one test coroutine's mark and the trace it records it in.
type Step = struct {
    trace: &Trace
    id: i32
}

// Gate is a trace shared by two test coroutines, and the one of them waiting to be woken.
type Gate = struct {
    trace: &Trace
    waiter: &Coroutine?
}

fn depth(n: i32) i32 {
    let buf: [u8; 4096] = [0; 4096]
    buf[4095] = n as u8
    const below = if n == 0 { 0 } else { depth(n - 1) + 1 }
    return below + (buf[4095] as i32) - ((n as u8) as i32)
}

#allow(W2004)
fn coroutine_test_addr(p: &u8) usize {
    return p as usize
}

fn coroutine_test_step_twice(arg: &u8) {
    const s = arg as &Step
    record(s.trace, s.id)
    reschedule()
    record(s.trace, s.id + 10)
}

fn coroutine_test_park_once(arg: &u8) {
    const g = arg as &Gate
    g.waiter = current_coroutine()
    record(g.trace, 1)
    park()
    record(g.trace, 3)
}

fn coroutine_test_wake_waiter(arg: &u8) {
    const g = arg as &Gate
    record(g.trace, 2)
    g.waiter.unwrap().wake()
}

fn coroutine_test_wake_self_then_park(arg: &u8) {
    current_coroutine().unwrap().wake()
    park()
    record(arg as &Trace, 7)
}

fn coroutine_test_noop(arg: &u8) {}

fn coroutine_test_cycle(arg: &u8) {
    const c = spawn(coroutine_test_noop, arg)
    run_coroutines()
    c.deinit()
}

fn coroutine_test_go_deep(arg: &u8) {
    const out = arg as &i32
    out.* = depth(50)
}

test "coroutines start in spawn order and interleave at each yield" {
    let t = Trace { steps = [0; 8], len = 0 }
    let a = Step { trace = &t, id = 1 }
    let b = Step { trace = &t, id = 2 }
    const ca = spawn(coroutine_test_step_twice, &a as &u8)
    const cb = spawn(coroutine_test_step_twice, &b as &u8)
    run_coroutines()
    assert_eq(t.len, 4, "steps")
    assert_eq(t.steps[0], 1, "a starts")
    assert_eq(t.steps[1], 2, "b starts")
    assert_eq(t.steps[2], 11, "a resumes")
    assert_eq(t.steps[3], 12, "b resumes")
    assert_true(ca.is_done() and cb.is_done(), "both finish")
    ca.deinit()
    cb.deinit()
}

test "a parked coroutine runs again only after a wake" {
    let t = Trace { steps = [0; 8], len = 0 }
    let g = Gate { trace = &t, waiter = null }
    const parker = spawn(coroutine_test_park_once, &g as &u8)
    const waker = spawn(coroutine_test_wake_waiter, &g as &u8)
    run_coroutines()
    assert_eq(t.len, 3, "steps")
    assert_eq(t.steps[0], 1, "parks")
    assert_eq(t.steps[1], 2, "wakes")
    assert_eq(t.steps[2], 3, "resumes")
    parker.deinit()
    waker.deinit()
}

test "a wake before the park it answers is kept" {
    let t = Trace { steps = [0; 8], len = 0 }
    const c = spawn(coroutine_test_wake_self_then_park, &t as &u8)
    run_coroutines()
    assert_eq(t.len, 1, "park returned")
    assert_true(c.is_done(), "finishes")
    c.deinit()
}

test "a parked coroutine never woken leaves run_coroutines" {
    let t = Trace { steps = [0; 8], len = 0 }
    let g = Gate { trace = &t, waiter = null }
    const c = spawn(coroutine_test_park_once, &g as &u8)
    run_coroutines()
    assert_true(!c.is_done(), "still parked")
    c.wake()
    run_coroutines()
    assert_true(c.is_done(), "finishes once woken")
    c.deinit()
}

test "a coroutine stack holds deep recursion" {
    let out: i32 = -1
    const c = spawn(coroutine_test_go_deep, &out as &u8)
    run_coroutines()
    assert_eq(out, 50, "depth")
    c.deinit()
}

test "context_address names the ctx the caller runs under" {
    const outer = coroutine_test_addr(context_address())
    const again = coroutine_test_addr(context_address())
    let inner = outer
    context(temp_allocator = context.allocator) {
        inner = coroutine_test_addr(context_address())
    }
    assert_true(outer == again, "one ctx while nothing rebinds")
    assert_true(outer != inner, "a rebind runs under a new ctx")
}

test "a finished coroutine is reused without allocating" {
    let unused: i32 = 0
    coroutine_test_cycle(&unused as &u8)
    let counter = counting_allocator(heap_allocator())
    let counted = allocator(&counter)
    scheduler.allocator = Some(&counted)
    for _i in 0usize..10usize {
        coroutine_test_cycle(&unused as &u8)
    }
    scheduler.allocator = null
    assert_eq(counter.allocs, 0, "no allocation for a reused coroutine")
}
