//! TEST: derived_bit_leaves
//! EXIT: 3

type Owner = struct {
    owned ptr: &u8
}

// `&T` and `T[]` are leaves of the derivation, so neither field makes `Viewer`
// non-copyable. A fixed array is not a leaf, so `Table` is.
type Viewer = struct {
    one: &Owner
    many: Owner[]
}

type Table = struct {
    slots: [Owner; 2]
}

fn take_viewer(v: Viewer) i32 {
    return 1
}

fn take_table(t: move Table) i32 {
    return 2
}

pub fn main() i32 {
    let v: Viewer
    let t: Table
    return take_viewer(v) + take_table(move t)
}
