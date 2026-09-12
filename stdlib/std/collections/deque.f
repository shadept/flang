// Double-ended queues over a ring buffer: push and pop at either end in amortised constant time.
// Use one as a queue (`push_back`, `pop_front`), as a stack (`push_back`, `pop_back`), or as a
// worklist that switches between the two.
//
// Two flavours, the managed and unmanaged split of spec §9.4. `Deque(T)` owns its buffer and its
// allocator (`dq.push_back(v)`); `UnmanagedDeque(T)` carries no allocator and takes one at every
// allocating call (`dq.push_back(v, alloc)`), for composites that keep one allocator for all their
// children.

import std.allocator
import std.mem
import std.option
import std.test

// A double-ended queue of `T` over a ring buffer, carrying no allocator: `push_back`, `push_front`
// and `deinit` take one as their last argument, and the same allocator must be passed every time. A
// zero-initialised value is a valid empty deque. Elements are owned: `deinit` deinits each.
pub type UnmanagedDeque = struct(T) {
    owned ptr: &T
    cap: usize // backing buffer capacity (in elements)
    head: usize // index of the front element when len > 0
    len: usize
}

// A double-ended queue of `T` that owns its ring buffer and remembers the allocator it grows and
// frees through. Every `UnmanagedDeque` operation applies to it as well, reached through
// `op_deref`, and the allocating ones come without the allocator argument. A zero-initialised value
// is a valid empty deque on the global allocator.
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

// Creates an empty unmanaged deque with room for `capacity` elements. Zero allocates nothing.
// Panics when the allocation fails.
//
// - `allocator`: grows and frees the buffer. Pass the same one to every allocating call.
pub fn unmanaged_deque(capacity: usize, allocator: &Allocator) UnmanagedDeque($T) {
    let out: UnmanagedDeque(T)
    if capacity > 0 {
        out.reserve(capacity, allocator)
    }
    return move out
}

// Creates an empty deque with room for `capacity` elements. Zero allocates nothing until the first
// push. Panics when the allocation fails.
//
// - `allocator`: kept for the deque's whole life. Null is the global allocator.
pub fn deque(capacity: usize, allocator: &Allocator? = null) Deque($T) {
    let out: Deque(T)
    out.allocator = allocator.or_global()
    out.__storage = unmanaged_deque(capacity, out.allocator)
    return move out
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

// Appends `value` at the back, growing when full. The deque owns it from here. Panics when the
// allocation fails.
pub fn push_back(self: &UnmanagedDeque($T), value: T, allocator: &Allocator) {
    self.reserve(self.len + 1, allocator)
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    slot.* = value
    self.len = self.len + 1
}

// Prepends `value` at the front, growing when full. The deque owns it from here. Panics when the
// allocation fails.
pub fn push_front(self: &UnmanagedDeque($T), value: T, allocator: &Allocator) {
    self.reserve(self.len + 1, allocator)
    // Wrap backwards. Adding cap-1 then mod cap avoids underflow on usize.
    self.head = (self.head + self.cap - 1) % self.cap
    const slot: &T = self.ptr + self.head
    slot.* = value
    self.len = self.len + 1
}

// Deinits every element, front to back, and frees the buffer. Idempotent: a second call is a no-op.
pub fn deinit(self: &UnmanagedDeque($T), allocator: &Allocator) {
    if self.cap > 0 {
        #if !type_info(T).copyable {
            for i in 0..self.len {
                const elem: &T = self.ptr + ((self.head + i) % self.cap)
                elem.deinit(allocator)
            }
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

// Returns whether there are no elements.
pub fn is_empty(self: &UnmanagedDeque($T)) bool {
    return self.len == 0
}

// Removes and returns the front element, or null when empty. The element is the caller's to deinit.
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

// Removes and returns the back element, or null when empty. The element is the caller's to deinit.
pub fn pop_back(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    self.len = self.len - 1
    const tail = (self.head + self.len) % self.cap
    const slot: &T = self.ptr + tail
    return Some(slot.*)
}

// Returns the front element without removing it, or null when empty.
pub fn peek_front(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    const slot: &T = self.ptr + self.head
    return Some(slot.*)
}

// Returns the back element without removing it, or null when empty.
pub fn peek_back(self: &UnmanagedDeque($T)) T? {
    if self.len == 0 {
        return null
    }
    const tail = (self.head + self.len - 1) % self.cap
    const slot: &T = self.ptr + tail
    return Some(slot.*)
}

// Drops every element without deiniting any; the buffer is kept for reuse. Elements that own
// something must be popped and deinited by the caller first.
pub fn clear(self: &UnmanagedDeque($T)) {
    self.head = 0
    self.len = 0
}

// =============================================================================
// Iterator (front-to-back)
// =============================================================================

// Iterator over a deque's elements, by value, front to back. A snapshot: the deque is not modified
// while it is being iterated.
pub type DequeIterator = struct(T) {
    deque: &UnmanagedDeque(T)
    current: usize // logical offset from head, 0 .. len
}

// Iterates the elements by value, front to back: `for x in dq`.
pub fn iter(self: &UnmanagedDeque($T)) DequeIterator(T) {
    return .{ deque = self, current = 0 }
}

// An iterator is its own iterable, so `for x in dq.iter()` and the std.iter combinators can consume
// it.
pub fn iter(self: &DequeIterator($T)) DequeIterator(T) {
    return self.*
}

// Advances and returns the next element, or null after the back.
pub fn next(self: &DequeIterator($T)) T? {
    if self.current >= self.deque.len {
        return null
    }
    const idx = (self.deque.head + self.current) % self.deque.cap
    const slot: &T = self.deque.ptr + idx
    self.current = self.current + 1
    return Some(slot.*)
}

// =============================================================================
// Deque: the managed API
// =============================================================================

// Appends `value` at the back, growing when full. The deque owns it from here. Panics when the
// allocation fails.
pub fn push_back(self: &Deque($T), value: T) {
    self.__storage.push_back(value, self.allocator)
}

// Prepends `value` at the front, growing when full. The deque owns it from here. Panics when the
// allocation fails.
pub fn push_front(self: &Deque($T), value: T) {
    self.__storage.push_front(value, self.allocator)
}

// Deinits every element, front to back, and frees the buffer. Idempotent: a second call is a no-op.
pub fn deinit(self: &Deque($T)) {
    self.__storage.deinit(self.allocator)
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &Deque($T), allocator: &Allocator) {
    self.deinit()
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
