//! TEST: error_e2003_type_not_found
//! COMPILE-ERROR: E2003

pub fn main() UnknownType {  // ERROR: cannot find type `UnknownType` in this scope
    return 0
}
