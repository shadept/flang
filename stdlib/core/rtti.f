// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.string

struct Type(T) {
    name: String
    size: u8
    align: u8
}

pub fn type_of(t: Type($T)) Type(T) {
    return t
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}

pub fn are_equal(a: $T, b: T) bool {
    return a == b
}
