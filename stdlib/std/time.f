// std.time — high-resolution monotonic clock for measuring intervals.
//
// `monotonic_ns()` returns nanoseconds since an unspecified epoch that
// is stable for the lifetime of the process. The reading IS NOT
// wall-clock time — it doesn't jump under NTP corrections, daylight
// saving, or manual clock changes — and IS NOT persistable across
// process restarts. Use it to time blocks of code, nothing else.
//
// Backed by `QueryPerformanceCounter` on Windows and
// `clock_gettime(CLOCK_MONOTONIC, ...)` on POSIX via time.c.
//
// A first-class `Time` / `Duration` value type, wall-clock readings,
// formatting, and parsing will live elsewhere when needed — this
// module is intentionally narrow.
//
// Typical use:
//
//   const t0 = monotonic_ns()
//   do_work()
//   const elapsed = elapsed_ns(t0)
//   println($"work took {ns_to_millis(elapsed)} ms".as_view())
//
// Or with the lighter `Stopwatch` wrapper:
//
//   let sw = stopwatch()
//   do_work()
//   const ms = sw.elapsed_millis()

#foreign fn __flang_monotonic_ns() u64

// Read the monotonic clock. Returns nanoseconds since the process's
// monotonic epoch (unspecified — only differences are meaningful).
pub fn monotonic_ns() u64 {
    return __flang_monotonic_ns()
}

// Nanoseconds elapsed from the reading `start` until now. Caller is
// responsible for capturing `start` via `monotonic_ns()` first. If
// `start` is in the future (clock-skew across cores in degenerate
// cases) the result is `0` rather than wrapping.
pub fn elapsed_ns(start: u64) u64 {
    const now = __flang_monotonic_ns()
    if now < start { return 0 }
    return now - start
}

// Convert a nanosecond duration to seconds as f64. Convenience for
// formatting — internal math should stay in ns to avoid float drift.
pub fn ns_to_seconds(ns: u64) f64 {
    return (ns as f64) / 1000000000.0
}

pub fn ns_to_millis(ns: u64) f64 {
    return (ns as f64) / 1000000.0
}

pub fn ns_to_micros(ns: u64) f64 {
    return (ns as f64) / 1000.0
}

// Convenience wrapper that captures a start instant and reports elapsed
// time on demand. Cheap to copy (one u64). Reset via `restart()` to
// reuse the same instance across phases.
pub type Stopwatch = struct {
    start_ns: u64
}

// Start a new stopwatch reading the monotonic clock at construction.
pub fn stopwatch() Stopwatch {
    return .{ start_ns = __flang_monotonic_ns() }
}

// Reset to "now". Use between phases when you want a single Stopwatch
// to time multiple back-to-back intervals.
pub fn restart(self: &Stopwatch) {
    self.start_ns = __flang_monotonic_ns()
}

pub fn elapsed_ns(self: Stopwatch) u64 {
    const now = __flang_monotonic_ns()
    if now < self.start_ns { return 0 }
    return now - self.start_ns
}

pub fn elapsed_micros(self: Stopwatch) f64 {
    return ns_to_micros(self.elapsed_ns())
}

pub fn elapsed_millis(self: Stopwatch) f64 {
    return ns_to_millis(self.elapsed_ns())
}

pub fn elapsed_seconds(self: Stopwatch) f64 {
    return ns_to_seconds(self.elapsed_ns())
}
