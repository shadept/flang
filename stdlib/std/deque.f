// Double-ended queues in two flavours, the managed and unmanaged split of spec §9.4:
// `UnmanagedDeque(T)` is the ring buffer and every operation on it, the allocating ones taking the
// allocator at the call (`dq.push_back(v, alloc)`); `Deque(T)` pairs it with an allocator
// (`dq.push_back(v)`), reaching the storage through `op_deref` so `dq.len` and `dq.pop_front()`
// read the same on either.
//
// Push/pop at either end run in amortised O(1). Use as a queue (push_back/pop_front), stack
// (push_back/pop_back), or worklist that flips ordering mid-algorithm.

import std.allocator
import std.mem
import std.option
import std.test

pub type UnmanagedDeque = struct(T) {
    ptr: &T
    cap: usize // backing buffer capacity (in elements)
    head: usize // index of the front element when len > 0
    len: usize
}

pub type Deque = struct(T) {
    __storage: UnmanagedDeque(T)
    allocator: &Allocator
}

// Reaches the storage: `dq.len`, `dq.pop_front()` and every `UnmanagedDeque` read resolve through
// this.
pub fn op_deref(self: &Deque($T)) &UnmanagedDeque(T) {
    return &self.__storage
}

const DEQUE_DEFAULT_CAPACITY: usize = 8

// Construct an empty unmanaged deque with room for `capacity` elements. Zero allocates nothing; a
// zero-initialised `UnmanagedDeque` is the same empty deque.
pub fn unmanaged_deque(capacity: usize, allocator: &Allocator) UnmanagedDeque($T) {
    let out: UnmanagedDeque(T)
    if capacity > 0 {
        out.reserve(capacity, allocator)
    }
    return out
}

// Construct an empty deque. The capacity hint pre-allocates storage to avoid early growth churn;
// pass 0 to defer allocation to the first push. `T` is inferred from context (e.g. `let dq:
// Deque(i32) = deque(0)`).
//
// - `allocator`: kept for the deque's whole life. Null is the global allocator.
pub fn deque(capacity: usize, allocator: &Allocator? = null) Deque($T) {
    let out: Deque(T)
    out.allocator = allocator.unwrap_or(0usize as &Allocator)
    out.__storage = unmanaged_deque(capacity, out.allocator)
    return out
}

// =============================================================================
// UnmanagedDeque: growth and release, allocator explicit
// =============================================================================

// Grow the backing buffer to at least `required` slots. When the live window wraps around the
// buffer end, growth flattens it back to head=0 so subsequent indexing stays simple.
fn reserve(self: &UnmanagedDeque($T), required: usize, allocator: &Allocator) {
    if self.cap >= required {
        return
    }

    let new_cap = if self.cap == 0 { DEQUE_DEFAULT_CAPACITY } else { self.cap * 2 }
    if new_cap < required {
        new_cap = required
    }

    const elem_size = size_of(T)
    const bytes = new_cap * elem_size
    const buf = allocator.alloc(bytes, align_of(T)).expect("deque: allocation failed")
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
        allocator.free(slice_from_raw_parts(self.ptr, self.cap))
    }
    self.ptr = new_ptr
    self.cap = new_cap
    self.head = 0
}

// Append a value to the back of the deque (queue enqueue / stack push).
pub fn push_back(self: &UnmanagedDeque($T), value: T, allocator: &Allocator) {
    self.reserve(self.len + 1, allocator)
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    slot.* = value
    self.len = self.len + 1
}

// Prepend a value to the front of the deque.
pub fn push_front(self: &UnmanagedDeque($T), value: T, allocator: &Allocator) {
    self.reserve(self.len + 1, allocator)
    // Wrap backwards. Adding cap-1 then mod cap avoids underflow on usize.
    self.head = (self.head + self.cap - 1) % self.cap
    const slot: &T = self.ptr + self.head
    slot.* = value
    self.len = self.len + 1
}

// Free the backing storage. Each live element's `deinit()` runs first, in logical (front-to-back)
// order. Idempotent.
pub fn deinit(self: &UnmanagedDeque($T), allocator: &Allocator) {
    if self.cap > 0 {
        for i in 0..self.len {
            const elem: &T = self.ptr + ((self.head + i) % self.cap)
            elem.deinit()
        }
        allocator.free(slice_from_raw_parts(self.ptr, self.cap))
    }
    self.ptr = 0usize as &T
    self.cap = 0
    self.head = 0
    self.len = 0
}

// =============================================================================
// UnmanagedDeque: in-place mutation and reads
// =============================================================================

pub fn is_empty(self: &UnmanagedDeque($T)) bool {
    return self.len == 0
}

// Remove and return the front element, or `null` when empty (queue dequeue).
pub fn pop_front(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    const slot: &T = self.ptr + self.head
    const v = slot.*
    self.head = (self.head + 1) % self.cap
    self.len = self.len - 1
    return Some(v)
}

// Remove and return the back element, or `null` when empty (stack pop).
pub fn pop_back(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    self.len = self.len - 1
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    return Some(slot.*)
}

// Read the front element without removing it.
pub fn peek_front(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    const slot: &T = self.ptr + self.head
    return Some(slot.*)
}

// Read the back element without removing it.
pub fn peek_back(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    const tail = (self.head + self.len - 1) % self.cap
    const slot: &T = self.ptr + tail
    return Some(slot.*)
}

// Drop every element. Backing storage is retained for reuse. Element `deinit()` is NOT called - use
// `deinit()` for a full release.
pub fn clear(self: &UnmanagedDeque($T)) {
    self.head = 0
    self.len = 0
}

// =============================================================================
// Iterator (front-to-back)
// =============================================================================

pub type DequeIterator = struct(T) {
    deque: &UnmanagedDeque(T)
    current: usize // logical offset from head, 0 .. len
}

pub fn iter(self: &UnmanagedDeque($T)) DequeIterator(T) {
    return .{ deque = self, current = 0 }
}

// An iterator is its own iterable, so `for x in dq.iter()` and the std.iter combinators can consume
// it.
pub fn iter(it: &DequeIterator($T)) DequeIterator(T) {
    return it.*
}

pub fn next(it: &DequeIterator($T)) T? {
    if it.current >= it.deque.len {
        return null
    }
    const idx = (it.deque.head + it.current) % it.deque.cap
    const slot: &T = it.deque.ptr + idx
    it.current = it.current + 1
    return Some(slot.*)
}

// =============================================================================
// Deque: the managed API
// =============================================================================

// Append a value to the back of the deque. Panics when the allocation fails.
pub fn push_back(self: &Deque($T), value: T) {
    self.__storage.push_back(value, self.allocator)
}

// Prepend a value to the front of the deque. Panics when the allocation fails.
pub fn push_front(self: &Deque($T), value: T) {
    self.__storage.push_front(value, self.allocator)
}

// Indexing and `for` resolve through `op_deref` since 2026-09-07 (spec.md §7), but the committed
// seed's checker still stops at the wrapper; these wrappers stay until the next promote.
pub fn iter(self: &Deque($T)) DequeIterator(T) {
    return self.__storage.iter()
}

// Free the backing storage. Each live element's `deinit()` runs first. Idempotent.
pub fn deinit(self: &Deque($T)) {
    self.__storage.deinit(self.allocator)
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedDeque takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let dq: UnmanagedDeque(i32) = unmanaged_deque(0, &alloc)
    dq.push_back(2i32, &alloc)
    dq.push_front(1i32, &alloc)
    dq.push_back(3i32, &alloc)
    assert_eq(dq.len, 3 as usize, "three pushes")
    let sum = 0i32
    for x in dq {
        sum = sum + x
    }
    assert_eq(sum, 6i32, "for front-to-back")
    assert_eq(dq.pop_front().unwrap(), 1i32, "front")
    assert_eq(dq.pop_back().unwrap(), 3i32, "back")
    dq.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "a wrapped window survives growth in order" {
    let dq: Deque(i32) = deque(4)
    defer dq.deinit()
    for i in 0..16usize {
        dq.push_back(i as i32)
        if dq.len > 2 {
            let _popped = dq.pop_front()
        }
    }
    let expected = 14i32
    for x in dq {
        assert_eq(x, expected, "elements drain in push order across the wrap")
        expected = expected + 1
    }
    assert_eq(expected, 16i32, "both survivors visited")
}
