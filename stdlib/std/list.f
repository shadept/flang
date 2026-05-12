// Generic dynamic array backed by manually managed heap storage.
// Uses raw malloc/free for simplicity (allocator support to be added later).

import std.allocator
import std.mem
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
        for i in 0..self.len as isize {
            const elem: &T = self.ptr + (i as usize)
            elem.deinit()
        }
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }

    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
}

pub fn as_slice(self: List($T)) T[] {
    return slice_from_raw_parts(self.ptr, self.len)
}

// Transfer ownership of the list's buffer as a `(T[], &Allocator)` pair.
// The slice is shrunk-to-fit (`cap == len` after the call) so no excess
// capacity is leaked. The list is reset to empty (ptr=null, cap=0) so a
// subsequent `deinit()` is a no-op — pair this with the
// `let l = list(...); defer l.deinit(); ...; l.to_owned_slice()` pattern.
//
// The returned `&Allocator` is the resolved allocator (global by default)
// — the caller frees the slice via
// `alloc.dealloc(slice_from_raw_parts(s.ptr as &u8, s.len * size_of(T)))`
// when done. Element `deinit()` is *not* called here; callers that own
// non-trivial elements must walk the slice and deinit each element
// before freeing the buffer.
pub fn to_owned_slice(self: &List($T)) (T[], &Allocator) {
    const alloc = self.allocator.or_global()
    const elem_size: usize = size_of(T)

    if self.len == 0 {
        if self.cap > 0 {
            alloc.free(slice_from_raw_parts(self.ptr, self.cap))
        }
        let zero: usize = 0
        self.ptr = zero as &T
        self.cap = 0
        const empty: T[] = slice_from_raw_parts(zero as &T, 0)
        return (empty, alloc)
    }

    if self.cap > self.len {
        const old_bytes = self.cap * elem_size
        const new_bytes = self.len * elem_size
        const old_slice = slice_from_raw_parts(self.ptr as &u8, old_bytes)
        const resized = alloc.realloc(old_slice, new_bytes)
        if resized.is_some() {
            self.ptr = resized.unwrap().ptr as &T
            self.cap = self.len
        }
    }

    const result_slice = slice_from_raw_parts(self.ptr, self.len)
    let zero: usize = 0
    self.ptr = zero as &T
    self.len = 0
    self.cap = 0
    return (result_slice, alloc)
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
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
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
#deprecated("Prefer index syntax: list[idx] = value")
pub fn set(list: &List($T), index: usize, value: T) {
    if index >= list.len {
        panic("List: index out of bounds")
    }

    // Write value using memcpy
    let dest: &u8 = (list.ptr + index) as &u8
    memcpy(dest, &value as &u8, size_of(T))
}

// Scalar indexing — ref-form. One function covers reads, writes, and
// address-of; the compiler desugars `list[i]`, `list[i] = v`, and `&list[i]`
// all through this. Panics on out-of-bounds.
pub fn op_index_ref(list: &List($T), index: usize) &T {
    if index >= list.len {
        panic("List: index out of bounds")
    }
    return list.ptr + index
}

// Range indexing: returns a sub-slice of the list's live elements.
// Out-of-bounds indices are clamped; an invalid range yields an empty slice.
// Value-form overload (returns a new slice); distinct idx type from the
// scalar ref-form below, so the two coexist without ambiguity.
pub fn op_index(list: List($T), range: Range(usize)) T[] {
    let start = range.start
    let end = range.end
    if start > list.len { start = list.len }
    if end > list.len { end = list.len }
    if start > end { end = start }
    return slice_from_raw_parts(list.ptr + start, end - start)
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
