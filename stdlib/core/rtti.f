// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.string
import core.slice

pub struct Field {
    name: String
    offset: usize
    type_info: &u8  // pointer to Type entry in the type table
}

struct Type(T) {
    name: String
    size: u8
    align: u8
    fields: Slice(Field)
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
