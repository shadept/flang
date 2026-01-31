// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.slice
import core.string

// Generic alias for TypeInfo.
// Allows couple of T to its TypeInfo.
pub struct Type(T) {}

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

pub fn type_of(t: Type($T)) TypeInfo {
    return t // auto coersed to TypeInfo
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}
