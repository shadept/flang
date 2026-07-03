//! TEST: index_with_option_range
//! COMPILE-ERROR: E2028
//! EXIT: 1

// Indexing a String with `Range(Option(usize))` (built from `0..find(...)`
// where `find` returns `Option(usize)`) must surface an error at the
// indexing site. Previously the bidirectional T <-> Option(T) coercion
// silently widened `0` into `Option(usize)`, hiding the real problem.

import std.string

fn parse(s: String) usize {
    const dp = s.find("..")
    const start_str = s[0..dp]
    return start_str.len
}

pub fn main() i32 { return 0 }
