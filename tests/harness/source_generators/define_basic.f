//! TEST: define_basic
//! EXIT: 0

// Simplest possible source generator: generate a function that returns a constant.

#define(make_zero, Name: Ident) {
    fn #(Name)() i32 {
        return 0
    }
}

#make_zero(my_zero)

pub fn main() i32 {
    return my_zero()
}
