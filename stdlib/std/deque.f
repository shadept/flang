// Generic double-ended queue backed by a power-of-two-amortised ring
// buffer. Push/pop at either end run in amortised O(1). Use as a queue
// (push_back/pop_front), stack (push_back/pop_back), or worklist that
// flips ordering mid-algorithm.

import std.allocator
import std.mem
import std.option

pub type Deque = struct(T) {
    ptr: &T
    cap: usize         // backing buffer capacity (in elements)
    head: usize        // index of the front element when len > 0
    len: usize
    allocator: &Allocator?
}

const DEQUE_DEFAULT_CAPACITY: usize = 8

// Construct an empty deque. The capacity hint pre-allocates storage to
// avoid early growth churn; pass 0 to defer allocation to the first push.
// `T` is inferred from context (e.g. `let dq: Deque(i32) = deque(0)`).
pub fn deque(capacity: usize, allocator: &Allocator? = null) Deque($T) {
    let result: Deque(T)
    result.allocator = allocator
    if capacity > 0 {
        result.reserve(capacity)
    }
    return result
}

// Free the backing storage. Each live element's `deinit()` runs first,
// in logical (front-to-back) order.
pub fn deinit(self: &Deque($T)) {
    if self.cap > 0 {
        for i in 0..self.len as isize {
            const logical: usize = (self.head + (i as usize)) % self.cap
            const elem: &T = self.ptr + logical
            elem.deinit()
        }
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }
    let zero: usize = 0
    self.ptr = zero as &T
    self.cap = 0
    self.head = 0
    self.len = 0
}

pub fn is_empty(self: Deque($T)) bool {
    return self.len == 0
}

// Grow the backing buffer to at least `required` slots. When the live
// window wraps around the buffer end, growth flattens it back to head=0
// so subsequent indexing stays simple.
fn reserve(self: &Deque($T), required: usize) {
    if self.cap >= required { return }

    let new_cap = if self.cap == 0 { DEQUE_DEFAULT_CAPACITY } else { self.cap * 2 }
    if new_cap < required { new_cap = required }

    const elem_size = size_of(T)
    const bytes = new_cap * elem_size
    const buf = self.allocator.or_global().alloc(bytes, align_of(T))
        .expect("deque: allocation failed")
    const new_ptr: &T = buf.ptr as &T

    if self.len > 0 {
        // Copy live window in logical order, flattening to start at index 0.
        const first_seg_len = if self.head + self.len <= self.cap { self.len } else { self.cap - self.head }
        memcpy(new_ptr as &u8, (self.ptr + self.head) as &u8, first_seg_len * elem_size)
        if first_seg_len < self.len {
            const second_seg_len = self.len - first_seg_len
            memcpy((new_ptr + first_seg_len) as &u8, self.ptr as &u8, second_seg_len * elem_size)
        }
    }
    if self.cap > 0 {
        self.allocator.or_global().free(slice_from_raw_parts(self.ptr, self.cap))
    }
    self.ptr = new_ptr
    self.cap = new_cap
    self.head = 0
}

// Append a value to the back of the deque (queue enqueue / stack push).
pub fn push_back(self: &Deque($T), value: T) {
    self.reserve(self.len + 1)
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    slot.* = value
    self.len = self.len + 1
}

// Prepend a value to the front of the deque.
pub fn push_front(self: &Deque($T), value: T) {
    self.reserve(self.len + 1)
    // Wrap backwards. Adding cap-1 then mod cap avoids underflow on usize.
    self.head = (self.head + self.cap - 1) % self.cap
    const slot: &T = self.ptr + self.head
    slot.* = value
    self.len = self.len + 1
}

// Remove and return the front element, or `null` when empty (queue dequeue).
pub fn pop_front(self: &Deque($T)) T? {
    if self.len == 0 { return null }
    const slot: &T = self.ptr + self.head
    const v = slot.*
    self.head = (self.head + 1) % self.cap
    self.len = self.len - 1
    return v
}

// Remove and return the back element, or `null` when empty (stack pop).
pub fn pop_back(self: &Deque($T)) T? {
    if self.len == 0 { return null }
    self.len = self.len - 1
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    return slot.*
}

// Read the front element without removing it.
pub fn peek_front(self: Deque($T)) T? {
    if self.len == 0 { return null }
    const slot: &T = self.ptr + self.head
    return slot.*
}

// Read the back element without removing it.
pub fn peek_back(self: Deque($T)) T? {
    if self.len == 0 { return null }
    const tail = (self.head + self.len - 1) % self.cap
    const slot: &T = self.ptr + tail
    return slot.*
}

// Drop every element. Backing storage is retained for reuse. Element
// `deinit()` is NOT called — use `deinit()` for a full release.
pub fn clear(self: &Deque($T)) {
    self.head = 0
    self.len = 0
}

// =============================================================================
// Iterator (front-to-back)
// =============================================================================

pub type DequeIterator = struct(T) {
    deque: &Deque(T)
    current: usize     // logical offset from head, 0 .. len
}

pub fn iter(self: &Deque($T)) DequeIterator(T) {
    return .{ deque = self, current = 0 }
}

pub fn next(it: &DequeIterator($T)) T? {
    if it.current >= it.deque.len { return null }
    const idx = (it.deque.head + it.current) % it.deque.cap
    const slot: &T = it.deque.ptr + idx
    it.current = it.current + 1
    return slot.*
}
