//! TEST: owned_reference_field
//! COMPILE-ERROR: E2124 `Cell` is not copyable
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

// `owned` on a reference-typed field sets the derived bit and nothing else: the reference stays a
// leaf of the walk, and the struct holding it is non-copyable.
type Cell = struct {
    owned p: &FileHandle
}

pub fn main() i32 {
    let h = FileHandle { fd = 3 }
    let c = Cell { p = &h }
    let d = c
    return d.p.fd
}
