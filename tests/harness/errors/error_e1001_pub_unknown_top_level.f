//! TEST: error_e1001_pub_unknown_top_level
//! COMPILE-ERROR: E1001 unexpected `while` after `pub`

// A `pub` that no declaration follows. The recovery must consume it: the module loop reopened the
// same error forever, allocating until the machine ran out of memory.
pub while

pub fn main() i32 {
    return 0
}
