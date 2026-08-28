//! TEST: index_with_option_range
//! COMPILE-ERROR: E2102
//! EXIT: 1

// Indexing a String with `Range(Option(usize))` (built from `0..find(...)`
// where `find` returns `Option(usize)`) must surface an error at the
// indexing site rather than widening `0` into `Option(usize)`. The literal
// carries a constraint to the numeric kinds, so building the range rejects
// it and the message names the type the literal was asked to become.

import std.string

fn parse(s: String) usize {
    const dp = s.find("..")
    const start_str = s[0..dp]
    return start_str.len
}

pub fn main() i32 { return 0 }
