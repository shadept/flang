// std.profile - control surface for the built-in instrumenting profiler (RFC-025).
//
// `flang build --profile` inserts a probe pair into every function and links profile.c, which
// aggregates the calls into a call tree. When the process exits, the runtime writes a flat table
// (calls, self, inclusive, per-call) to stderr, sorted by self time. Set FLANG_PROFILE_OUT to a
// path to also write folded stacks - one line per call path - which speedscope.app, inferno, or
// flamegraph.pl render as a flamegraph. FLANG_PROFILE_NODES / FLANG_PROFILE_DEPTH resize the
// runtime's node pool and shadow stack when a report says it overflowed.
//
// This module is only needed to control the profiler mid-run; a plain `--profile` build reports at
// exit without it. In a build without `--profile` both calls are no-ops.

#foreign fn __flang_prof_dump() void
#foreign fn __flang_prof_reset() void

// Write the profile collected so far: the flat table to stderr, and folded stacks to
// FLANG_PROFILE_OUT when set. Counters keep accumulating - the exit report still covers the whole
// run.
pub fn dump() {
    __flang_prof_dump()
}

// Zero every counter while keeping the call tree's shape, so the next dump covers only what ran
// after this call. Frames currently on the profiler's stack keep their entry timestamps: a function
// that was already running when reset() fired reports its full span, not the post-reset part.
pub fn reset() {
    __flang_prof_reset()
}
