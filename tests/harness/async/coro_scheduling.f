//! TEST: coro_scheduling
//! EXIT: 0

// Coroutines run in spawn order, interleave at yields, resume from park only after a wake, and hold
// deep recursion.

import std.option
import std.runtime.coro

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
    peer: &Coroutine?
}

fn step_twice(arg: &u8) {
    const s: &Step = arg as &Step
    record(s.trace, s.id)
    reschedule()
    record(s.trace, s.id + 10)
}

fn park_once(arg: &u8) {
    const s: &Step = arg as &Step
    s.peer = current_coroutine()
    record(s.trace, 1)
    park()
    record(s.trace, 3)
}

fn wake_peer(arg: &u8) {
    const s: &Step = arg as &Step
    record(s.trace, 2)
    s.peer.unwrap().wake()
}

fn depth(n: i32) i32 {
    let buf: [u8; 4096] = [0; 4096]
    buf[4095] = n as u8
    const below: i32 = if n == 0 { 0 } else { depth(n - 1) + 1 }
    return below + (buf[4095] as i32) - ((n as u8) as i32)
}

fn go_deep(arg: &u8) {
    const out: &i32 = arg as &i32
    out.* = depth(50)
}

pub fn main() i32 {
    let t: Trace = Trace { steps = [0; 8], len = 0 }
    let a: Step = Step { trace = &t, id = 1, peer = null }
    let b: Step = Step { trace = &t, id = 2, peer = null }
    const ca: &Coroutine = spawn(step_twice, &a as &u8)
    const cb: &Coroutine = spawn(step_twice, &b as &u8)
    run_coroutines()
    if t.len != 4 or t.steps[0] != 1 or t.steps[1] != 2 or t.steps[2] != 11 or t.steps[3] != 12 {
        return 1
    }
    if !ca.is_done() or !cb.is_done() {
        return 2
    }
    ca.deinit()
    cb.deinit()

    let u: Trace = Trace { steps = [0; 8], len = 0 }
    let g: Step = Step { trace = &u, id = 0, peer = null }
    const parker: &Coroutine = spawn(park_once, &g as &u8)
    const waker: &Coroutine = spawn(wake_peer, &g as &u8)
    run_coroutines()
    if u.len != 3 or u.steps[0] != 1 or u.steps[1] != 2 or u.steps[2] != 3 {
        return 3
    }
    parker.deinit()
    waker.deinit()

    let out: i32 = -1
    const deep: &Coroutine = spawn(go_deep, &out as &u8)
    run_coroutines()
    if out != 50 {
        return 4
    }
    deep.deinit()
    return 0
}
