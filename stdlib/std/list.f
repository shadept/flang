// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import std.allocator
import std.option
import std.sort

pub type List = struct(T) {
    ptr: &T
    len: usize
    cap: usize
    allocator: &Allocator?
}

const DEFAULT_CAPACITY: usize = 16

pub fn list(capacity: usize, allocator: &Allocator? = null) List($T) {
    if capacity == 0 {
        let empty: List(T)
        empty.allocator = allocator
        return empty
    }
    const bytes = capacity * size_of(T)
    const buf = allocator.or_global().alloc(bytes, align_of(T))
        .expect("list: allocation failed")

    return .{
        ptr = buf.ptr as &T,
        len = 0,
        cap = capacity,
        allocator = allocator,
    }
}

// Create a shallow copy of an existing list.
// Allocates new backing storage and copies all elements.
pub fn list(source: List($T), allocator: &Allocator? = null) List(T) {
    if source.len == 0 {
        let empty: List(T)
        empty.allocator = allocator
        return empty
    }
    const bytes = source.len * size_of(T)
    const buf = allocator.or_global().alloc(bytes, align_of(T))
        .expect("list(copy): allocation failed")
    memcpy(buf.ptr, source.ptr as &u8, bytes)
    return .{
        ptr = buf.ptr as &T,
        len = source.len,
        cap = source.len,
        allocator = allocator,
    }
}

// Free the backing storage. The list should not be used after this.
// Calls deinit on all stored elements before freeing.
pub fn deinit(self: &List($T)) {
    if self.cap > 0 {
        // Deinit all live elements
        for (i in 0..self.len as isize) {
            const elem: &T = self.ptr + (i as usize)
            elem.deinit()
        }
        const slice = slice_from_raw_parts(self.ptr as &u8, self.cap * size_of(T))
        self.allocator.or_global().dealloc(slice)
    }

    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
}

pub fn as_slice(self: List($T)) T[] {
    return slice_from_raw_parts(self.ptr, self.len)
}

pub fn reserve(self: &List($T), capacity: usize) {
    if self.cap >= capacity {
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
    if self.len > 0 {
        const old_bytes = self.len * elem_size
        memcpy(new_ptr as &u8, self.ptr as &u8, old_bytes)
    }

    // Free old buffer if it existed
    if self.cap > 0 {
        self.allocator.or_global().dealloc(slice_from_raw_parts(self.ptr as &u8, self.cap * elem_size))
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
    if list.len == 0 {
        return null
    }

    list.len = list.len - 1
    let last: &T = list.ptr + list.len
    return last.*
}

// Get the element at the given index.
pub fn get(list: List($T), index: usize) T? {
    if index >= list.len { return null }
    let elem: &T = list.ptr + index
    return elem.*
}

// Get the element at the given index.
pub fn get_ref(list: List($T), index: usize) &T? {
    if index >= list.len { return null }
    let elem: &T = list.ptr + index
    return elem
}

// Set the element at the given index.
// Panics if index is out of bounds.
pub fn set(list: &List($T), index: usize, value: T) {
    if index >= list.len {
        panic("List: index out of bounds")
    }

    // Write value using memcpy
    let dest: &u8 = (list.ptr + index) as &u8
    memcpy(dest, &value as &u8, size_of(T))
}

pub fn op_index(list: List($T), index: usize) T {
    if index >= list.len {
        panic("List: index out of bounds")
    }

    let elem: &T = list.ptr + index
    return elem.*
}

// Range indexing: returns a sub-slice of the list's live elements.
// Out-of-bounds indices are clamped; an invalid range yields an empty slice.
pub fn op_index(list: List($T), range: Range(usize)) T[] {
    let start = range.start
    let end = range.end
    if start > list.len { start = list.len }
    if end > list.len { end = list.len }
    if start > end { end = start }
    return .{ ptr = list.ptr + start, len = end - start }
}

// Ref-form indexer, selected by the compiler when the list is addressed via
// `&list[i]`. Returns a pointer to the live element so callers can read or
// mutate it without copying. Panics on out-of-bounds.
pub fn op_index_ref(list: &List($T), index: usize) &T {
    if index >= list.len {
        panic("List: index out of bounds")
    }
    return list.ptr + index
}

// Borrow the element at `index` — returns `&T` and panics on out-of-bounds.
// Use this when you need to read or mutate the element in place without
// copying. The reference is valid until the list is reallocated
// (push/reserve) or deinit'd.
// Prefer `&list[i]` which resolves to `op_index_ref` — this function is kept
// for callers that want an explicit method form.
pub fn at_ref(list: &List($T), index: usize) &T {
    return list.op_index_ref(index)
}

pub fn op_set_index(list: &List($T), index: usize, value: T) {
    list.set(index, value)
}

// Remove all elements from the list without freeing memory.
pub fn clear(list: &List($T)) {
    list.len = 0
}

pub fn sort(list: &List($T)) {
    sort(list.as_slice())
}

pub fn sort(list: &List($T), cmp: fn(T, T) Ord) {
    sort(list.as_slice(), cmp)
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
    if it.current >= it.list.len {
        return null
    }

    const elem = it.list.get(it.current)
    it.current = it.current + 1
    return elem
}
