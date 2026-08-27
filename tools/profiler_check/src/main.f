// Ground-truth workload for validating the RFC-025 profiler (`flang -p build`). Every function here
// has a call count and a self-time budget the caller can predict, so `check.ps1` can compare the
// profiler's flat table and folded output against known values:
//
//   spin_leaf_a   300 calls x 1 ms  self ~300 ms, no callees
//   spin_leaf_b   150 calls x 2 ms  self ~300 ms, no callees
//   middle        100 calls         self ~100 ms (1 ms own burn), incl ~500 ms
//   deep_recur    1 outer call, depth 50, 51 calls total, ~51 ms inclusive counted ONCE
//   ping / pong   mutual recursion, ping burns 1 ms/call, pong 3 ms/call - self must
//                 attribute per function, not smear across the cycle
//   maybe_fail    50 calls, half return early through `?` - pairing must survive early returns
//
// Each function burns time with its own busy-wait loop on the monotonic clock (std.time is
// uninstrumented stdlib, so the burn bills to the enclosing frame's self). The loop is written out
// in every function rather than shared: a helper would be an instrumented frame of its own and
// absorb exactly the self time these budgets pin down.
//
// stdout carries the ground truth (wall time of the measured region and expected counts) for the
// checker to parse; the profiler's own output goes to stderr / FLANG_PROFILE_OUT.

import std.env
import std.option
import std.profile
import std.result
import std.time

const MS: u64 = 1000000

fn spin_leaf_a() {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 1 * MS {
    }
}

fn spin_leaf_b() {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 2 * MS {
    }
}

// Self ~1 ms per call; inclusive adds two leaf_a (2 ms) and one leaf_b (2 ms).
fn middle() {
    spin_leaf_a()
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 1 * MS {
    }
    spin_leaf_a()
    spin_leaf_b()
}

// Direct recursion: 51 calls per outer invocation, ~1 ms self each. Inclusive must count the
// outermost span once (~51 ms), never once per level.
fn deep_recur(n: i64) i64 {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 1 * MS {
    }
    if n <= 0 {
        return 0
    }
    return deep_recur(n - 1) + 1
}

// Mutual recursion with asymmetric self time: ping burns 1 ms per call, pong 3 ms. The profiler
// must bill each function its own burn - the historical failure mode smears the whole cycle's time
// into whichever frame sits between recursive re-entries.
fn ping(n: i64) i64 {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 1 * MS {
    }
    if n <= 0 {
        return 0
    }
    return pong(n - 1)
}

fn pong(n: i64) i64 {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 3 * MS {
    }
    return ping(n)
}

// Early return through `?`: exit probes must fire on BOTH paths or the shadow stack corrupts and
// every later attribution is garbage.
fn maybe_fail(n: i64) Result(i64, String) {
    const t0 = monotonic_ns()
    while elapsed_ns(t0) < 1 * MS {
    }
    if n % 2 == 0 {
        return Err("even")
    }
    return Ok(n)
}

fn try_some(n: i64) Result(i64, String) {
    const v = maybe_fail(n)?
    return Ok(v + 1)
}

pub fn main() i32 {
    const t0 = monotonic_ns()

    for _i in 0..100usize {
        spin_leaf_a()
        middle()
    }
    for _i in 0..50usize {
        spin_leaf_b()
    }

    const r = deep_recur(50)

    let acc: i64 = 0
    for _i in 0..10usize {
        acc = acc + ping(20)
    }

    let ok: i64 = 0
    for i in 0..50i64 {
        try_some(i) match {
            Ok(_) => { ok = ok + 1 }
            Err(_) => {}
        }
    }

    const measured_ns = elapsed_ns(t0)

    // Ground truth for check.ps1. Counts are exact; times are lower bounds the burns guarantee.
    println("GROUND wall_ms")
    println(measured_ns / 1000000)
    println("GROUND leaf_a_calls 300")
    println("GROUND leaf_b_calls 150")
    println("GROUND middle_calls 100")
    println("GROUND deep_recur_calls 51")
    println("GROUND ping_calls 210")
    println("GROUND pong_calls 200")
    println("GROUND maybe_fail_calls 50")
    println(r + acc + ok)

    // Phase-scoped profiling (PROFCHECK_PHASES=1): everything above is window one; dump it, reset,
    // run a small tail whose numbers must NOT include window one. The exit dump then covers only
    // the tail.
    if env("PROFCHECK_PHASES").is_some() {
        dump()
        reset()
        for _i in 0..20usize {
            spin_leaf_a()
        }
        println("GROUND tail_leaf_a_calls 20")
    }
    return 0
}
