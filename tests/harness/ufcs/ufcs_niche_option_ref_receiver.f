//! TEST: ufcs_niche_option_ref_receiver
//! EXIT: 0

import std.option

// A pointer-niche `Option(&T)` is an aggregate by shape and a scalar by representation: its value
// IS the payload pointer, so a place holding one has to be ADDRESSED to reach a `&Option(&T)`
// parameter, never loaded. Loading it hands the callee the payload pointer where it expects the
// option's address, and a `None` receiver then dereferences null.

type Page = struct {
    size: usize
}

fn present(o: &Option($T)) bool {
    return o.* match {
        Some(_) => true
        None => false
    }
}

pub fn main() i32 {
    let empty: &Page? = null
    if empty.present() {
        return 1
    }
    if !empty.is_none() {
        return 2
    }

    let page = Page { size = 8 }
    let filled: &Page? = Some(&page)
    if !filled.present() {
        return 3
    }
    if !filled.is_some() {
        return 4
    }

    // The tagged layout takes the same path and must keep working.
    let n: i32? = Some(5i32)
    if !n.present() {
        return 5
    }
    return 0
}
