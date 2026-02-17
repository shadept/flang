// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.slice
import core.string

pub type TypeKind = enum {
    Primitive = 0
    Array = 1
    Struct = 2
    Enum = 3
}

// Generic alias for TypeInfo.
// Allows couple of T to its TypeInfo.
pub type Type = struct(T) {}

pub type TypeInfo = struct {
    name: String
    size: u8
    align: u8
    kind: TypeKind
    type_params: String[]
    type_args: &TypeInfo[]
    fields: FieldInfo[]
}

pub type FieldInfo = struct {
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
