//! TEST: define_variadic
//! EXIT: 0

// Test variadic generator parameters (..Params: Kind)

#define(multi, Name: Ident, ..Tags: Ident) {
    fn #(Name)() i32 {
        return #(Tags.len)
    }
}

#multi(count_zero)
#multi(count_one, a)
#multi(count_three, a, b, c)

#define(greet, ..Names: Ident) {
    #for name in Names {
        fn hello_#(name)() i32 { return 1 }
    }
}

#greet(alice, bob)

pub fn main() i32 {
    if count_zero() != 0 { return 1 }
    if count_one() != 1 { return 2 }
    if count_three() != 3 { return 3 }

    if hello_alice() != 1 { return 4 }
    if hello_bob() != 1 { return 5 }

    return 0
}
