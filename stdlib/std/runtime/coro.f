// std.runtime.coro - stackful coroutines scheduled on the calling thread (RFC-005, one worker).
//
// A coroutine runs only inside the run loop, which drives every runnable coroutine on the thread
// that enters it and returns once none is runnable. A coroutine runs until it finishes, yields or
// parks; a parked one runs again only after a wake. A wake that arrives before the park it answers
// is kept, so that park returns at once. Each coroutine owns its own stack, which never grows or
// moves; overflowing it faults on a guard page.
//
// Internal: the runtime beneath the task API, not an API for programs.

import std.allocator
import std.option
import std.test

pub type Coro = #foreign struct {}

#foreign fn __flang_coro_spawn(entry: #foreign fn(&u8), arg: &u8, stack_size: usize) &Coro
#foreign fn __flang_coro_run()
#foreign fn __flang_coro_yield()
#foreign fn __flang_coro_park()
#foreign fn __flang_coro_wake(c: &Coro)
#foreign fn __flang_coro_current() &Coro?
#foreign fn __flang_coro_is_done(c: &Coro) i32
#foreign fn __flang_coro_free(c: &Coro)

// Create a coroutine that calls the entry with the argument on its own stack. It first runs inside
// the run loop.
pub fn spawn(entry: #foreign fn(&u8), arg: &u8) &Coro {
    return __flang_coro_spawn(entry, arg, 0)
}

// Run coroutines on this thread until none is runnable. Aborts when called inside a coroutine.
pub fn run() {
    __flang_coro_run()
}

// Let every other runnable coroutine run once, then continue. Aborts outside a coroutine.
pub fn yield_now() {
    __flang_coro_yield()
}

// Suspend until a wake, or return at once if one is already pending. Aborts outside a coroutine.
pub fn park() {
    __flang_coro_park()
}

// Make a parked coroutine runnable; for one not parked, make its next park return at once.
pub fn wake(self: &Coro) {
    __flang_coro_wake(self)
}

// The running coroutine, or null outside one.
pub fn current() &Coro? {
    return __flang_coro_current()
}

pub fn is_done(self: &Coro) bool {
    return __flang_coro_is_done(self) != 0
}

// Free a finished coroutine. Aborts when it has not finished.
pub fn deinit(self: &Coro) {
    __flang_coro_free(self)
}

// The address of the context the caller runs under, so the runtime can run a task body under its
// scope's context. Only the standard library may call it, and the compiler answers only a direct
// call; reached any other way it panics.
#intrinsic
pub fn context_address() &u8 {
    panic("context_address answers only a direct call")
}

type Trace = struct {
    steps: [i32; 8]
    len: usize
}

fn record(t: &Trace, v: i32) {
    t.steps[t.len] = v
    t.len = t.len + 1
}

type Step = struct {
    trace: &Trace
    id: i32
}

type Gate = struct {
    trace: &Trace
    waiter: &Coro?
}

fn depth(n: i32) i32 {
    let buf: [u8; 4096] = [0; 4096]
    buf[4095] = n as u8
    const below = if n == 0 { 0 } else { depth(n - 1) + 1 }
    return below + (buf[4095] as i32) - ((n as u8) as i32)
}

#foreign fn __flang_coro_test_step_twice(arg: &u8) {
    const s = arg as &Step
    record(s.trace, s.id)
    yield_now()
    record(s.trace, s.id + 10)
}

#foreign fn __flang_coro_test_park_once(arg: &u8) {
    const g = arg as &Gate
    g.waiter = current()
    record(g.trace, 1)
    park()
    record(g.trace, 3)
}

#foreign fn __flang_coro_test_wake_waiter(arg: &u8) {
    const g = arg as &Gate
    record(g.trace, 2)
    g.waiter.unwrap().wake()
}

#foreign fn __flang_coro_test_wake_self_then_park(arg: &u8) {
    current().unwrap().wake()
    park()
    record(arg as &Trace, 7)
}

#foreign fn __flang_coro_test_go_deep(arg: &u8) {
    const out = arg as &i32
    out.* = depth(50)
}

test "coroutines start in spawn order and interleave at each yield" {
    let t = Trace { steps = [0; 8], len = 0 }
    let a = Step { trace = &t, id = 1 }
    let b = Step { trace = &t, id = 2 }
    const ca = spawn(__flang_coro_test_step_twice, &a as &u8)
    const cb = spawn(__flang_coro_test_step_twice, &b as &u8)
    run()
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
    const parker = spawn(__flang_coro_test_park_once, &g as &u8)
    const waker = spawn(__flang_coro_test_wake_waiter, &g as &u8)
    run()
    assert_eq(t.len, 3, "steps")
    assert_eq(t.steps[0], 1, "parks")
    assert_eq(t.steps[1], 2, "wakes")
    assert_eq(t.steps[2], 3, "resumes")
    parker.deinit()
    waker.deinit()
}

test "a wake before the park it answers is kept" {
    let t = Trace { steps = [0; 8], len = 0 }
    const c = spawn(__flang_coro_test_wake_self_then_park, &t as &u8)
    run()
    assert_eq(t.len, 1, "park returned")
    assert_true(c.is_done(), "finishes")
    c.deinit()
}

test "a parked coroutine never woken leaves run" {
    let t = Trace { steps = [0; 8], len = 0 }
    let g = Gate { trace = &t, waiter = null }
    const c = spawn(__flang_coro_test_park_once, &g as &u8)
    run()
    assert_true(!c.is_done(), "still parked")
    c.wake()
    run()
    assert_true(c.is_done(), "finishes once woken")
    c.deinit()
}

test "a coroutine stack holds deep recursion" {
    let out: i32 = -1
    const c = spawn(__flang_coro_test_go_deep, &out as &u8)
    run()
    assert_eq(out, 50, "depth")
    c.deinit()
}

test "context_address names the link the caller runs under" {
    const outer = context_address() as usize
    const again = context_address() as usize
    let inner = outer
    context(temp_allocator = context.allocator) {
        inner = context_address() as usize
    }
    assert_true(outer == again, "one link while nothing rebinds")
    assert_true(outer != inner, "a rebind runs under a new link")
}
