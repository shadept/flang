// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

pub fn size_of(t: Type($T)) usize {
    return t.size as usize
}

pub fn align_of(t: Type($T)) usize {
    return t.align as usize
}
