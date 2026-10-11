//! TEST: contract_param_bound
//! EXIT: 9

// A contract's own parameter takes its bound inline.
type Into = contract(T: copyable) {
    fn into(self: Self) T
}

type Meters = struct {
    v: i32
}

fn into(self: Meters) i32 {
    return self.v
}

fn convert(x: $X) i32 where X: Into(i32) {
    return x.into()
}

pub fn main() i32 {
    return convert(Meters { v = 9 })
}
