// Types laid out for C, and the conversions from their FLang counterparts.

import std.test

// Text as C reads it: `len` bytes at `ptr`, laid out as `{ const char *ptr; size_t len; }`. Not
// NUL-terminated: a C reader takes the length from `len`.
pub type FString = #foreign struct {
    ptr: &u8
    len: usize
}

pub fn view(c: FString) String {
    return from_c_string(c.ptr, Some(c.len))
}

pub fn to_fstr(s: String) FString {
    return .{ ptr = s.ptr, len = s.len }
}

test "a string survives the round trip through its C layout" {
    const c = "flang".to_fstr()
    assert_true(c.len == 5usize, "length carried, not measured")
    assert_true(c.view() == "flang", "same text back")
}
