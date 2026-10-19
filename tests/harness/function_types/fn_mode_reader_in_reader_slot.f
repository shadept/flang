//! TEST: fn_mode_reader_in_reader_slot
//! EXIT: 0

// A function that reads its parameter fills a reading slot for any type: the caller lends the
// value and keeps it (RFC-037).

import std.string

fn len_of(s: OwnedString) usize {
    return s.len
}

fn measure(s: &OwnedString, f: fn(OwnedString) usize) usize {
    return f(s.*)
}

pub fn main() i32 {
    const s: OwnedString = from_view("owned")
    const n: usize = measure(&s, len_of)
    const again: usize = s.len
    s.deinit()
    return (n + again) as i32 - 10
}
