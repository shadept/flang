//! TEST: error_e1024_unterminated_interp_string
//! COMPILE-ERROR: E1024

pub fn main() i32 {
    let x = $"unterminated
    return 0
}
