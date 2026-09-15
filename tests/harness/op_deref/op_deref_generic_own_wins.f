//! TEST: op_deref_generic_own_wins
//! EXIT: 1

type Inner = struct {
    n: i32
}

pub fn describe(self: &Inner) i32 {
    return 7
}

type Wrap = struct(T) {
    value: T
}

pub fn op_deref(self: &Wrap($T)) &T {
    return &self.value
}

pub fn describe(self: &Wrap($T)) i32 {
    return 1
}

// A wrapper's own generic overload, adapted to `&w`, wins over the inner type's through the hop.
pub fn main() i32 {
    const w = Wrap(Inner) { value = Inner { n = 0 } }
    return w.describe()
}
