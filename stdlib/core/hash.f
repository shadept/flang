// Hashing for the hashed containers: the `Hash` contract, and the `hash` overloads every program
// gets.
//
// `u32`, `u64`, `usize`, `i32` and `i64` are mixed directly; every other copyable type, the other
// integer widths included, falls to the generic byte hash. `String` (core.string) and `OwnedString`
// (std.string) hash their content. Hashes are deterministic and unseeded: the same value hashes the
// same in every run, so a table keyed on untrusted input can be driven into collisions.

import core.rtti

// A type with a `hash`: an overload of its own, or the byte hash for a copyable one. What `Dict`,
// `Set` and `MultiMap` require of a key, beside `Eq`.
//
// Values `==` calls equal must hash equal; the containers find nothing otherwise. A type whose `==`
// looks through a reference, or ignores part of the value, declares its own `hash` to match.
pub type Hash = contract {
    fn hash(self: Self) usize
}

// Integer keys skip the byte loop: one mix beats four to eight FNV rounds and distributes better.
// Every width the compiler keys a Dict on has an overload here - a missing one silently falls back
// to the generic form, which is correct but slower.

// Mixes `val`'s bits across the whole word.
pub fn hash(val: u32) usize {
    return mix64(val as u64) as usize
}

// Mixes `val`'s bits across the whole word.
pub fn hash(val: u64) usize {
    return mix64(val) as usize
}

// Mixes `val`'s bits across the whole word.
pub fn hash(val: usize) usize {
    return mix64(val as u64) as usize
}

// Mixes `val`'s bits across the whole word. Sign-extends first, so an `i32` hashes as the `i64` of
// the same value.
pub fn hash(val: i32) usize {
    return mix64((val as i64) as u64) as usize
}

// Mixes `val`'s bits across the whole word.
pub fn hash(val: i64) usize {
    return mix64(val as u64) as usize
}

// Hashes the value `val` points to, not its address: a reference key hashes as the value would.
pub fn hash(val: &$T) usize where T: copyable {
    return hash(val.*)
}

// FNV-1a over every byte of `val`, padding included: aggregate construction zeroes padding (spec
// 4.2), so equal values hash equal.
//
// A reference or a view inside `val` hashes its address and length, not what it points to; `0.0`
// and `-0.0` compare equal and hash apart. Such a type declares its own `hash`, or derives a
// field-wise one (`#derive(T, hash)`, std.derive).
pub fn hash(val: $T) usize where T: copyable {
    const bytes: &u8 = &val as &u8
    const size: usize = size_of(T)
    let h: usize = 14695981039346656037
    for i in 0..size {
        const byte: &u8 = bytes + i as usize
        h = (h ^ (byte.* as usize)) * 1099511628211
    }
    return h
}

// SplitMix64's finalizer. Two multiply-xorshift rounds spread every input bit across the whole
// word, which is what open addressing with linear probing needs: the low bits pick the slot, and
// dense counter-like keys (registry ids, node fingerprints) must not land in a run.
fn mix64(x: u64) u64 {
    let h: u64 = x
    h = (h ^ (h >> 30u64)) * 13787848793156543929u64
    h = (h ^ (h >> 27u64)) * 10723151780598845931u64
    return h ^ (h >> 31u64)
}
