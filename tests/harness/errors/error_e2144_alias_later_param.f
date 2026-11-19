//! TEST: error_e2144_alias_later_param
//! COMPILE-ERROR: E2144
//! EXIT: 1

// An alias's bound reads only the parameters before it.
type Check(F: fn(T) bool, T) = (F, T) // error E2144

pub fn main() i32 {
    return 0
}
