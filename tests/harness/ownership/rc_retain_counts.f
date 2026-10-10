//! TEST: rc_retain_counts
//! EXIT: 21

import std.rc

// `retain` takes a second count on the same value; each handle's `deinit` gives one back.
pub fn main() i32 {
    let r: Rc(i32) = rc(7i32)
    let r2 = r.retain()
    const shared = r2.ref_count()
    r2.deinit()
    const left = r.ref_count()
    r.deinit()
    return (shared * 10 + left) as i32
}
