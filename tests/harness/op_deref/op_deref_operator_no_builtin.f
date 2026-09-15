//! TEST: op_deref_operator_no_builtin
//! COMPILE-ERROR: E2017
//! EXIT: 1

type Box = struct {
    inner: i32
}

fn op_deref(self: &Box) &i32 {
    return &self.inner
}

// Only an operator function is reached through a hop: a wrapped primitive does not become a builtin
// compare.
pub fn main() i32 {
    const b = Box { inner = 7 }
    if b == b {
        return 1
    }
    return 0
}
