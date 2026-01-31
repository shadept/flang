// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.string
import core.slice

pub struct TypeInfo {
    name: String
    size: u8
    align: u8
    fields: FieldInfo[]
}

pub struct FieldInfo {
    name: String
    offset: usize
    type: &TypeInfo
}

struct Type(T) {}

pub fn type_of(t: Type($T)) Type(T) {
    return t
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}
