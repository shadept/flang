// Generic hash map (dictionary) backed by manually managed heap storage.
// Uses open addressing with linear probing for collision resolution.
// Supports an optional allocator; defaults to global_allocator when null.
//
// NOTE: Full implementation is blocked by a compiler bug where modifying
// fields of generic structs via reference causes the compiler to hang.
// See docs/known-issues.md for details.

import core.runtime

import std.allocator
import std.option

// A single entry in the hash map.
struct Entry(K, V) {
    hash: usize
    key: K
    value: V
}

pub struct Dict(K, V) {
    entries: &Entry(K, V)
    len: usize
    cap: usize
    allocator: Allocator?
}

// Returns the allocator for this dict, defaulting to global_allocator if none set.
pub fn allocator(self: Dict($K, $V)) Allocator {
    return self.allocator ?? global_allocator()
}

// Create a new empty dict using the global allocator.
pub fn dict_new() Dict($K, $V) {
    let zero: usize = 0
    return .{ entries = zero as &Entry(K, V), len = 0, cap = 0, allocator = null }
}

// Create a new empty dict with a specific allocator.
pub fn dict_with_allocator(alloc: Allocator) Dict($K, $V) {
    let zero: usize = 0
    return .{ entries = zero as &Entry(K, V), len = 0, cap = 0, allocator = alloc }
}

// Returns the number of key-value pairs in the dict.
pub fn len(self: Dict($K, $V)) usize {
    return self.len
}

// Returns true if the dict is empty.
pub fn is_empty(self: Dict($K, $V)) bool {
    return self.len == 0
}

// Set is blocked by compiler bug - see docs/known-issues.md
pub fn set(dict: Dict($K, $V), key: K, value: V) {
    __flang_unimplemented()
}

// Get is blocked by compiler bug - see docs/known-issues.md
pub fn get(dict: Dict($K, $V), key: K) V? {
    __flang_unimplemented()
    return null
}

// Contains is blocked by compiler bug - see docs/known-issues.md
pub fn contains(dict: Dict($K, $V), key: K) bool {
    __flang_unimplemented()
    return false
}

// Remove is blocked by compiler bug - see docs/known-issues.md
pub fn remove(dict: Dict($K, $V), key: K) V? {
    __flang_unimplemented()
    return null
}

// Clear is blocked by compiler bug - see docs/known-issues.md
pub fn clear(dict: Dict($K, $V)) {
    __flang_unimplemented()
}

// Deinit is blocked by compiler bug - see docs/known-issues.md
pub fn deinit(dict: Dict($K, $V)) {
    __flang_unimplemented()
}
