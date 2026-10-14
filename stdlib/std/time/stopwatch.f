// std.time.stopwatch - a start instant on the monotonic clock (std.time.clock), and the time
// elapsed since.
//
//   let sw = stopwatch()
//   do_work()
//   const ms = sw.elapsed_millis()

import std.time.clock
import std.time.duration

// Convenience wrapper that captures a start instant and reports elapsed time on demand. Cheap to
// copy (one u64). Reset via `restart()` to reuse the same instance across phases.
pub type Stopwatch = struct {
    start_ns: u64
}

// Start a new stopwatch reading the monotonic clock at construction.
pub fn stopwatch() Stopwatch {
    return .{ start_ns = monotonic_ns() }
}

// Reset to "now". Use between phases when you want a single Stopwatch to time multiple back-to-back
// intervals.
pub fn restart(self: &Stopwatch) {
    self.start_ns = monotonic_ns()
}

pub fn elapsed_ns(self: Stopwatch) u64 {
    const now = monotonic_ns()
    if now < self.start_ns {
        return 0
    }
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

pub fn elapsed(self: Stopwatch) Duration {
    return nanoseconds(self.elapsed_ns() as i64)
}
