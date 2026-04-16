//! TEST: dse_address_of_escapes
//! EXIT: 42

// Taking a reference to a local causes the alloca to "escape" — its
// address is observable elsewhere. DSE must NOT eliminate stores to
// such allocas even if the current function never reads them directly.

fn read_through(p: &i32) i32 {
    return p.*
}

pub fn main() i32 {
    let x: i32 = 42
    let pr = &x
    return read_through(pr)
}
