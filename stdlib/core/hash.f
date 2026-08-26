// Generic FNV-1a hash for any type, with a mixing shortcut for the integer widths.
//
// The generic form hashes the raw bytes of a value using FNV-1a. Types with custom hash semantics
// (e.g. String) provide their own hash() overload, which the compiler prefers over the generic one.

import core.rtti

// SplitMix64's finalizer. Two multiply-xorshift rounds spread every input bit across the whole
// word, which is what open addressing with linear probing needs: the low bits pick the slot, and
// dense counter-like keys (registry ids, node fingerprints) must not land in a run.
fn mix64(x: u64) u64 {
    let h: u64 = x
    h = (h ^ (h >> 30u64)) * 13787848793156543929u64
    h = (h ^ (h >> 27u64)) * 10723151780598845931u64
    return h ^ (h >> 31u64)
}

// Integer keys skip the byte loop: one mix beats four to eight FNV rounds and distributes better.
// Every width the compiler keys a Dict on has an overload here - a missing one silently falls back
// to the generic form, which is correct but slower.
pub fn hash(val: u32) usize {
    return mix64(val as u64) as usize
}

pub fn hash(val: u64) usize {
    return mix64(val) as usize
}

pub fn hash(val: usize) usize {
    return mix64(val as u64) as usize
}

pub fn hash(val: i32) usize {
    return mix64((val as i64) as u64) as usize
}

pub fn hash(val: i64) usize {
    return mix64(val as u64) as usize
}

pub fn hash(val: &$T) usize {
    return hash(val.*)
}

pub fn hash(val: $T) usize {
    const bytes: &u8 = &val as &u8
    const size: usize = size_of(T)
    let h: usize = 14695981039346656037
    for i in 0..size {
        const byte: &u8 = bytes + i as usize
        h = (h ^ (byte.* as usize)) * 1099511628211
    }
    return h
}
