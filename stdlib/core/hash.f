// Generic FNV-1a hash for any type.
//
// Hashes the raw bytes of a value using the FNV-1a algorithm.
// Types with custom hash semantics (e.g. String) should provide their own
// hash() overload which will be preferred by the compiler.

import core.rtti

pub fn hash(val: &$T) usize {
    return hash(val.*)
}

pub fn hash(val: $T) usize {
    const bytes: &u8 = &val as &u8
    const size: usize = size_of(T)
    let h: usize = 14695981039346656037
    for (i in 0..size) {
        const byte: &u8 = bytes + i as usize
        h = (h ^ (byte.* as usize)) * 1099511628211
    }
    return h
}
