// Generic dynamic array backed by manually managed heap storage.
// Supports an optional allocator; defaults to global_allocator when null.
//
// NOTE: Full implementation is blocked by a compiler bug where modifying
// fields of generic structs via reference causes the compiler to hang.
// See docs/known-issues.md for details.

import core.runtime

import std.allocator
import std.option

pub struct List(T) {
    ptr: &T
    len: usize
    cap: usize
    allocator: Allocator?
}

// Returns the allocator for this list, defaulting to global_allocator if none set.
pub fn allocator(self: List($T)) Allocator {
    return self.allocator ?? global_allocator()
}

// Create a new empty list using the global allocator.
pub fn list_new() List($T) {
    let zero: usize = 0
    return .{ ptr = zero as &T, len = 0, cap = 0, allocator = null }
}

// Create a new empty list with a specific allocator.
pub fn list_with_allocator(alloc: Allocator) List($T) {
    let zero: usize = 0
    return .{ ptr = zero as &T, len = 0, cap = 0, allocator = alloc }
}

// Returns the number of elements in the list.
pub fn len(self: List($T)) usize {
    return self.len
}

// Returns true if the list is empty.
pub fn is_empty(self: List($T)) bool {
    return self.len == 0
}

// Push is blocked by compiler bug - see docs/known-issues.md
pub fn push(list: List($T), value: T) {
    __flang_unimplemented()
}

// Pop is blocked by compiler bug - see docs/known-issues.md
pub fn pop(list: List($T)) T? {
    __flang_unimplemented()
    return null
}

// Get is blocked by compiler bug - see docs/known-issues.md
pub fn get(list: List($T), index: usize) T {
    __flang_unimplemented()
    let zero: usize = 0
    return zero as T
}

// Set is blocked by compiler bug - see docs/known-issues.md
pub fn set(list: List($T), index: usize, value: T) {
    __flang_unimplemented()
}

// Clear is blocked by compiler bug - see docs/known-issues.md
pub fn clear(list: List($T)) {
    __flang_unimplemented()
}

// Deinit is blocked by compiler bug - see docs/known-issues.md
pub fn deinit(list: List($T)) {
    __flang_unimplemented()
}
