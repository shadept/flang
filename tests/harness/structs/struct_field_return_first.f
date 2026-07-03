//! TEST: struct_field_return_first
//! EXIT: 7

// The first field (offset 0) of a never-address-taken struct literal must
// load correctly too — the companion to struct_field_return_nonfirst, so the
// pair pins both the offset-0 and offset-!=0 field loads in a bare return.

type Pt = struct {
    x: i32,
    y: i32
}

fn main() i32 {
    let p = Pt { x = 7, y = 4 }
    return p.x
}
