// std.time.clock - the process's two clocks.
//
// `now()` reads the wall clock: the current Instant, from the system's realtime clock. It can jump
// when the system clock is set or corrected, so it is for timestamps, not for measuring.
//
// `monotonic_ns()` returns nanoseconds since an unspecified epoch that is stable for the lifetime
// of the process. The reading IS NOT wall-clock time - it doesn't jump under NTP corrections,
// daylight saving, or manual clock changes - and IS NOT persistable across process restarts. Use it
// to time blocks of code, nothing else; `Stopwatch` (std.time.stopwatch) wraps it.
//
// Backed by clock.c: `QueryPerformanceCounter` and `GetSystemTimePreciseAsFileTime` on Windows,
// `clock_gettime` on POSIX.
//
// Typical use:
//
//   const t0 = monotonic_ns()
//   do_work()
//   const elapsed = elapsed_ns(t0)
//   const msg = $"work took {ns_to_millis(elapsed)} ms"
//   defer msg.deinit()
//   println(msg.as_view())

import std.time.instant

#foreign fn __flang_realtime_ticks() i64

// The current instant, from the system's realtime clock.
pub fn now() Instant {
    return Instant { ticks = __flang_realtime_ticks() }
}

#foreign fn __flang_monotonic_ns() u64

// Read the monotonic clock. Returns nanoseconds since the process's monotonic epoch (unspecified -
// only differences are meaningful).
pub fn monotonic_ns() u64 {
    return __flang_monotonic_ns()
}

// Nanoseconds elapsed from the reading `start` until now. Caller is responsible for capturing
// `start` via `monotonic_ns()` first. If `start` is in the future (clock-skew across cores in
// degenerate cases) the result is `0` rather than wrapping.
pub fn elapsed_ns(start: u64) u64 {
    const now = __flang_monotonic_ns()
    if now < start {
        return 0
    }
    return now - start
}

// Convert a nanosecond duration to seconds as f64. Convenience for formatting - internal math
// should stay in ns to avoid float drift.
pub fn ns_to_seconds(ns: u64) f64 {
    return (ns as f64) / 1000000000.0
}

pub fn ns_to_millis(ns: u64) f64 {
    return (ns as f64) / 1000000.0
}

pub fn ns_to_micros(ns: u64) f64 {
    return (ns as f64) / 1000.0
}
