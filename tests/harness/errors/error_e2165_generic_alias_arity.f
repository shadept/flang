//! TEST: error_e2165_generic_alias_arity
//! COMPILE-ERROR: E2165

// A generic alias takes exactly the arguments it declares: none left for later, none extra
// (RFC-047).
type Pairs(K, V) = (K, V)[]

fn take(p: Pairs(i32)) i32 { // error[E2165]
    return 0
}

pub fn main() i32 {
    const n: usize = size_of(Pairs(i32, u8, u8)) // error[E2165]
    return n as i32
}
