// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import std.allocator
import std.option

pub type List = struct(T) {
    ptr: &T
    len: usize
    cap: usize
    allocator: &Allocator?
}

const DEFAULT_CAPACITY: usize = 16

pub fn list(capacity: usize, allocator: &Allocator? = null) List($T) {
    const bytes = capacity * size_of(T)
    const buf = allocator.alloc(bytes, align_of(T))
        .expect("list: allocation failed")

    return List {
        ptr = buf.ptr,
        len = 0,
        cap = capacity,
        allocator = allocator,
    }
}

// Free the backing storage. The list should not be used after this.
pub fn deinit(self: &List($T)) {
    if (self.cap > 0) {
        let old_ptr: &u8? = self.ptr as &u8
        self.allocator.or_global().free(self.as_slice())
    }

    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
}

fn as_slice(self: List($T)) T[] {
    return slice_from_raw_parts(self.ptr, self.len)
}

pub fn reserve(self: &List($T), capacity: usize) {
    if (self.cap >= capacity) {
        return
    }

    // Calculate new capacity: start with 4, then double
    let new_cap = if self.cap == 0 { DEFAULT_CAPACITY } else { self.cap * 2 }
    if new_cap < capacity {
        new_cap = capacity
    }

    // Allocate new buffer using raw malloc
    const elem_size: usize = size_of(T)
    const elem_align: usize = align_of(T)
    const new_bytes: usize = new_cap * elem_size
    const new_buf = self.allocator.or_global().alloc(new_bytes, elem_align)
        .expect("reserve(List(T), capacity): allocation failed")
    const new_ptr: &T = new_buf.ptr as &T

    // Copy existing elements
    if (self.len > 0) {
        const old_bytes = self.len * elem_size
        memcpy(new_ptr as &u8, self.ptr as &u8, old_bytes)
    }

    // Free old buffer if it existed
    if (self.cap > 0) {
        free(self.ptr as &u8)
    }

    self.ptr = new_ptr
    self.cap = new_cap
}

// Append an element to the end of the list.
pub fn push(self: &List($T), value: T) {
    self.reserve(self.len + 1)

    // Write value at index len using memcpy
    self.len = self.len + 1
    let data = self.as_slice()
    data[self.len - 1] = value
    // let dest: &u8 = (self.ptr + self.len) as &u8
    // memcpy(dest, &value as &u8, type.size as usize)
}

// Remove and return the last element, or null if empty.
pub fn pop(list: &List($T)) T? {
    if (list.len == 0) {
        return null
    }

    list.len = list.len - 1
    let last: &T = list.ptr + list.len
    return last.*
}

// Get the element at the given index.
// Panics if index is out of bounds.
pub fn get(list: List($T), index: usize) T {
    if (index >= list.len) {
        panic("List: index out of bounds")
    }

    let elem: &T = list.ptr + index
    return elem.*
}

// Set the element at the given index.
// Panics if index is out of bounds.
pub fn set(list: &List($T), index: usize, value: T) {
    if (index >= list.len) {
        panic("List: index out of bounds")
    }

    // Write value using memcpy
    let dest: &u8 = (list.ptr + index) as &u8
    memcpy(dest, &value as &u8, size_of(T))
}

// Remove all elements from the list without freeing memory.
pub fn clear(list: &List($T)) {
    list.len = 0
}

// =============================================================================
// List Iterator
// =============================================================================

pub type ListIterator = struct(T) {
    list: &List(T)
    current: usize
}

// Create iterator from list
pub fn iter(l: &List($T)) ListIterator(T) {
    return .{ list = l, current = 0 }
}

// Advance iterator and return next value
pub fn next(it: &ListIterator($T)) T? {
    if (it.current >= it.list.len) {
        return null
    }

    const elem = it.list.get(it.current)
    it.current = it.current + 1
    return elem
}
