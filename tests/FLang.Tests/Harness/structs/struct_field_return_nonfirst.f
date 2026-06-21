//! TEST: struct_field_return_nonfirst
//! EXIT: 4

// Reading a non-first field of a never-address-taken struct literal must load
// at the field's byte offset, not constant-fold to zero. Regression — a field
// load at offset != 0 once mis-typed to `void*` and folded to `(void*)(0 + 0)`,
// so `return p.y` returned 0 while `return p.x` (offset 0) was correct.

type Pt = struct {
    x: i32,
    y: i32
}

fn main() i32 {
    let p = Pt { x = 7, y = 4 }
    return p.y
}
