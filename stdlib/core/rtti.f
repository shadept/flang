// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.string

struct Type(T) {
    name: String
    size: u8
    aling: u8
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}
