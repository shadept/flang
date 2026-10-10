//! TEST: rc_clone_peels_to_value
//! EXIT: 2

import std.rc
import std.string

// `clone` on a handle is the value's own `clone`, reached through `op_deref`: a fresh owned copy,
// not another count.
pub fn main() i32 {
    let r = rc(from_view("ab"))
    let copy: OwnedString = r.clone()
    const n = copy.len as i32
    copy.deinit()
    const count = r.ref_count() as i32
    r.deinit()
    return n * count
}
