//! TEST: contract_anonymous
//! EXIT: 9

type Box = struct {
    v: i32
}

fn get(self: &Box) i32 {
    return self.v
}

// A contract written where it is used; the `$T` it introduces names the return type.
fn read_twice(b: &$B) T where B: contract { fn get(self: &Self) $T }, T: copyable {
    const x: T = b.get()
    return x
}

pub fn main() i32 {
    const b = Box { v = 9 }
    return read_twice(&b)
}
