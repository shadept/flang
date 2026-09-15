//! TEST: op_deref_as_written_beats_hop
//! EXIT: 102

type Name = struct {
    text: i32
}

pub fn label(n: Name) i32 {
    return 1
}

pub fn label(n: &$T) i32 {
    return 10
}

pub fn label(n: $T) i32 {
    return 100
}

type Handle = struct {
    name: Name
}

fn op_deref(self: &Handle) &Name {
    return &self.name
}

// Compare the instantiations: `label(Name)` for `n` (the concrete overload is more specific than
// `label($T)` at the same cost), `label(Handle)` for `h` (exact). Reaching `label(Name)` from `h`
// would mean `label(h.op_deref())`, which is more work, so the peel is only a fallback.
pub fn main() i32 {
    const h = Handle { name = Name { text = 0 } }
    const n = Name { text = 0 }
    return h.label() + n.label() + 1
}
