// Generic hash map (dictionary) backed by manually managed heap storage.
// Uses open addressing with linear probing for collision resolution.
//
// NOTE: Full implementation is blocked - requires while loop support.
// FLang currently only supports for-in loops, which don't support:
// - Conditional early exit (break)
// - Complex state tracking across iterations
// - Infinite loops with break conditions
//
// TODO: Implement when while loops are added to FLang (milestone TBD)

import core.mem
import core.panic
import core.runtime

import std.option

// A single entry in the hash map.
pub struct Entry(K, V) {
    state: u8
    hash: usize
    key: K
    value: V
}

pub struct Dict(K, V) {
    entries: &Entry(K, V)
    length: usize
    cap: usize
    key_size: usize
    value_size: usize
    entry_size: usize
}

// Create a new empty dict.
// Type parameters are used to capture key and value sizes at creation time.
pub fn dict_new(key_type: Type($K), value_type: Type($V)) Dict(K, V) {
    let zero: usize = 0
    // Entry layout: u8 state + padding + usize hash + K key + V value
    let entry_size: usize = 16 + (key_type.size as usize) + (value_type.size as usize)
    return .{
        entries = zero as &Entry(K, V),
        length = 0,
        cap = 0,
        key_size = key_type.size as usize,
        value_size = value_type.size as usize,
        entry_size = entry_size
    }
}

// Returns the number of key-value pairs in the dict.
pub fn len(self: &Dict($K, $V)) usize {
    return self.length
}

// Returns true if the dict is empty.
pub fn is_empty(self: &Dict($K, $V)) bool {
    return self.length == 0
}

// Blocked: requires while loop support
pub fn set(dict: &Dict($K, $V), key: K, value: V) {
    __flang_unimplemented()
}

// Blocked: requires while loop support
pub fn get(dict: &Dict($K, $V), key: K) V? {
    __flang_unimplemented()
    return null
}

// Blocked: requires while loop support
pub fn contains(dict: &Dict($K, $V), key: K) bool {
    __flang_unimplemented()
    return false
}

// Blocked: requires while loop support
pub fn remove(dict: &Dict($K, $V), key: K) V? {
    __flang_unimplemented()
    return null
}

// Remove all entries from the dict without freeing memory.
pub fn clear(dict: &Dict($K, $V)) {
    if (dict.cap > 0) {
        let bytes: usize = dict.cap * dict.entry_size
        memset(dict.entries as &u8, 0, bytes)
    }
    dict.length = 0
}

// Free the backing storage. The dict should not be used after this.
pub fn deinit(dict: &Dict($K, $V)) {
    if (dict.cap > 0) {
        let old_ptr: &u8? = dict.entries as &u8
        free(old_ptr)
    }

    let zero: usize = 0
    dict.entries = zero as &Entry(K, V)
    dict.length = 0
    dict.cap = 0
}
