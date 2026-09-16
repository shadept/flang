//! TEST: swap_exchanges_owners
//! EXIT: 21

type Handle = struct {
    owned fd: i32
}

fn deinit(self: move Handle) {
}

// `swap` exchanges two owning values with no copy and no byte-level helper: core declares its
// parameters `&move`, so the body may take from each slot as long as it refills both.
pub fn main() i32 {
    let a = Handle { fd = 4 }
    let b = Handle { fd = 17 }
    swap(&a, &b)
    const total = a.fd * 1 + b.fd * 1
    if a.fd != 17 {
        return 1
    }
    if b.fd != 4 {
        return 2
    }
    a.deinit()
    b.deinit()
    return total
}
