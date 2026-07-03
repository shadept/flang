//! TEST: if_directive_testing
//! EXIT: 0

// Tests compile-time #if with runtime.testing (should be false in normal compilation).

pub fn main() i32 {
    let result: i32 = 10
    #if(runtime.testing) {
        result = 99
    } else {
        result = 0
    }
    return result
}
