//! TEST: op_deref_operator_generic_hop
//! EXIT: 3

type Wrap = struct(T) {
    value: T
}

fn op_deref(self: &Wrap($T)) &T {
    return &self.value
}

type Id = struct {
    n: i32
}

fn op_eq(a: Id, b: Id) bool {
    return a.n == b.n
}

// A generic `op_deref` hop specializes per operand type.
pub fn main() i32 {
    const a = Wrap(Id) { value = Id { n = 5 } }
    const b = Id { n = 5 }
    let n = 0
    if a == b { n = n + 1 }
    if b == a { n = n + 2 }
    return n
}
