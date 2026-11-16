//! TEST: local_type_scopes
//! EXIT: 37

// RFC-046: an inner scope shadows a module-level type and an outer local one; sibling blocks
// declare distinct types of one name; a nested block, a loop body and a lambda see the types of the
// scopes around them.

type Kind = struct {
    v: i32
}

fn module_kind() i32 {
    const k = Kind { v = 1 }
    return k.v
}

fn apply(f: fn() i32) i32 {
    return f()
}

pub fn main() i32 {
    type Kind = struct {
        v: i32
        w: i32
    }
    let total: i32 = 0
    {
        type Kind = enum {
            Small
            Big(i32)
        }
        const k: Kind = Big(10)
        total = total + k match {
            Small => 0
            Big(n) => n
        }
    }
    {
        type Kind = struct {
            only: i32
        }
        const k = Kind { only = 10 }
        total = total + k.only
    }
    const outer = Kind { v = 5, w = 5 }
    for i in 0..2 {
        const inner = Kind { v = i, w = 1 }
        total = total + inner.w
    }
    total = total + apply { Kind { v = 3, w = 4 }.w }
    return total + outer.v + outer.w + module_kind()
}
