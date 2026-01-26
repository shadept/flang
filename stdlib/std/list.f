// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import core.mem
import core.panic
import core.rtti

import std.option

pub struct List(T) {
    ptr: &T
    len: usize
    cap: usize
}

// Create a new empty list.
pub fn list_new(type: Type($T)) List(T) {
    let zero: usize = 0
    return .{
        ptr = zero as &T,
        len = 0,
        cap = 0
    }
}

// Returns the number of elements in the list.
pub fn len(self: List($T)) usize {
    return self.len
}

// Returns true if the list is empty.
pub fn is_empty(self: List($T)) bool {
    return self.len == 0
}

// Append an element to the end of the list.
pub fn push(list: &List($T), value: T) {
    const type: Type(T) = T
    let min_cap: usize = list.len + 1
    if (list.cap < min_cap) {
        let elem_size: usize = type.size as usize

        // Calculate new capacity: start with 4, then double
        let new_cap: usize = if (list.cap == 0) 4 else list.cap * 2
        if (new_cap < min_cap) {
            new_cap = min_cap
        }

        // Allocate new buffer using raw malloc
        let new_bytes: usize = new_cap * elem_size
        let new_buf: &u8? = malloc(new_bytes)
        if (new_buf.is_none()) {
            panic("List: allocation failed")
        }

        let new_ptr: &T = new_buf.value as &T

        // Copy existing elements
        if (list.len > 0) {
            let old_bytes: usize = list.len * elem_size
            memcpy(new_ptr as &u8, list.ptr as &u8, old_bytes)
        }

        // Free old buffer if it existed
        if (list.cap > 0) {
            let old_ptr: &u8? = list.ptr as &u8
            free(old_ptr)
        }

        list.ptr = new_ptr
        list.cap = new_cap
    }

    // Write value at index len using memcpy
    let dest: &u8 = (list.ptr + list.len) as &u8
    memcpy(dest, &value as &u8, type.size as usize)

    list.len = list.len + 1
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

    const type: Type(T) = T

    // Write value using memcpy
    let dest: &u8 = (list.ptr + index) as &u8
    memcpy(dest, &value as &u8, type.size as usize)
}

// Remove all elements from the list without freeing memory.
pub fn clear(list: &List($T)) {
    list.len = 0
}

// Free the backing storage. The list should not be used after this.
pub fn deinit(list: &List($T)) {
    if (list.cap > 0) {
        let old_ptr: &u8? = list.ptr as &u8
        free(old_ptr)
    }

    let zero: usize = 0
    list.ptr = zero as &T
    list.len = 0
    list.cap = 0
}
