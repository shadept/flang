//! TEST: pub_import_parses
//! EXIT: 7

// Sanity check: `pub import` is recognized by the parser. Behavior of the
// re-export itself is exercised by the multi-module suite added in Phase 7.

pub import core.io

pub fn main() i32 {
    return 7
}
