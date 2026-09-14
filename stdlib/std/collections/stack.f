// Last-in, first-out stacks: `push` and `pop` at the top, `peek` to read it, iteration from either
// end.
//
// Two flavours, the managed and unmanaged split of spec §9.4. `Stack(T)` owns its storage and its
// allocator (`s.push(v)`); `UnmanagedStack(T)` carries no allocator and takes one at every
// allocating call (`s.push(v, alloc)`), for composites that keep one allocator for all their
// children. Both are a list restricted to its end, so a stack costs what the list does and
// `as_slice` exposes the elements bottom to top.

import std.allocator
import std.collections.list
import std.option
import std.test

// A last-in, first-out stack of `T` that carries no allocator: `push` and `deinit` take one as
// their last argument, and the same allocator must be passed every time. A zero-initialised value
// is a valid empty stack. Elements are owned: `deinit` deinits each.
pub type UnmanagedStack = struct(T) {
    __inner: UnmanagedList(T)
}

// A last-in, first-out stack of `T` that owns its storage and remembers the allocator it grows and
// frees through. Every `UnmanagedStack` operation applies to it as well, reached through
// `op_deref`, and `push` comes without the allocator argument. A zero-initialised value is a valid
// empty stack on the global allocator.
pub type Stack = struct(T) {
    __storage: UnmanagedStack(T)
    allocator: &Allocator
}

// Reaches the storage: `s.len()`, `s.pop()` and every `UnmanagedStack` read resolve through this.
pub fn op_deref(self: &Stack($T)) &UnmanagedStack(T) {
    return &self.__storage
}

// Creates an empty unmanaged stack with room for `capacity` elements. Zero allocates nothing.
// Panics when the allocation fails.
//
// - `allocator`: grows and frees the storage. Pass the same one to every allocating call.
pub fn unmanaged_stack(capacity: usize, allocator: &Allocator) UnmanagedStack($T) {
    return .{ __inner = unmanaged_list(capacity, allocator) }
}

// Creates an empty stack with room for `capacity` elements. Zero allocates nothing until the first
// `push`. Panics when the allocation fails.
//
// - `allocator`: kept for the stack's whole life. Null is the global allocator.
pub fn stack(capacity: usize, allocator: &Allocator? = null) Stack($T) {
    let out: Stack(T)
    out.allocator = allocator.or_global()
    out.__storage = unmanaged_stack(capacity, out.allocator)
    return out
}

// =============================================================================
// UnmanagedStack: growth and release, allocator explicit
// =============================================================================

// Pushes `value` on top, growing when full. The stack owns it from here. Panics when the allocation
// fails.
pub fn push(self: &UnmanagedStack($T), value: T, allocator: &Allocator) {
    self.__inner.push(value, allocator)
}

// Deinits every element and frees the storage. Idempotent: a second call is a no-op.
pub fn deinit(self: &UnmanagedStack($T), allocator: &Allocator) {
    self.__inner.deinit(allocator)
}

// =============================================================================
// UnmanagedStack: in-place mutation and reads
// =============================================================================

// Returns the number of elements.
pub fn len(self: &UnmanagedStack($T)) usize {
    return self.__inner.len
}

// Returns whether there are no elements.
pub fn is_empty(self: &UnmanagedStack($T)) bool {
    return self.__inner.len == 0
}

// Removes and returns the top element, or null when empty. The element is the caller's to deinit.
pub fn pop(self: &UnmanagedStack($T)) T? {
    return self.__inner.pop()
}

// Returns the top element without removing it, or null when empty.
pub fn peek(self: &UnmanagedStack($T)) T? {
    return self.__inner.last()
}

// Returns a reference to the top element, or null when empty. Writes through it land in the stack;
// a push may move the storage and invalidate it.
pub fn peek_ref(self: &UnmanagedStack($T)) &T? {
    if self.__inner.len == 0 {
        return null
    }
    return self.__inner.get_ref(self.__inner.len - 1)
}

// Removes every element, deiniting each. The storage is kept for reuse.
pub fn clear(self: &UnmanagedStack($T)) {
    self.__inner.clear()
}

// Returns a view of the elements, bottom to top. Growth moves the storage and invalidates the view.
pub fn as_slice(self: &UnmanagedStack($T)) T[] {
    return self.__inner.as_slice()
}

// Iterates the elements by value, bottom to top: `for x in s`. The stack is not modified while it
// is being iterated.
pub fn iter(self: &UnmanagedStack($T)) SliceIterator(T) {
    return self.__inner.iter()
}

// Iterates the elements by value, top to bottom, the order `pop` would yield them, without removing
// any. The stack is not modified while it is being iterated.
pub fn iter_rev(self: &UnmanagedStack($T)) SliceRevIterator(T) {
    return self.__inner.iter_rev()
}

// =============================================================================
// Stack: the managed API
// =============================================================================

// Pushes `value` on top, growing when full. The stack owns it from here. Panics when the allocation
// fails.
pub fn push(self: &Stack($T), value: T) {
    self.__storage.push(value, self.allocator)
}

// Deinits every element and frees the storage. Idempotent: a second call is a no-op.
pub fn deinit(self: &Stack($T)) {
    self.__storage.deinit(self.allocator)
}

// =============================================================================
// Tests
// =============================================================================

test "an UnmanagedStack takes its allocator at every allocating call" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let s: UnmanagedStack(i32) = unmanaged_stack(0, &alloc)
    s.push(1i32, &alloc)
    s.push(2i32, &alloc)
    assert_eq(s.len(), 2usize, "two pushes")
    let first_popped = 0i32
    for x in s.iter_rev() {
        if first_popped == 0 {
            first_popped = x
        }
    }
    assert_eq(first_popped, 2i32, "iter_rev starts at the top")
    let bottom_up = 0i32
    for x in s {
        bottom_up = bottom_up * 10 + x
    }
    assert_eq(bottom_up, 12i32, "for walks bottom to top")
    assert_eq(s.peek().unwrap(), 2i32, "peek sees the top")
    assert_eq(s.pop().unwrap(), 2i32, "pop returns the top")
    s.deinit(&alloc)
    assert_eq(counting.live_bytes, 0 as usize, "everything went back through that allocator")
}

test "stack push/pop is LIFO" {
    let s: Stack(i32) = stack(0)
    defer s.deinit()
    s.push(1i32)
    s.push(2i32)
    s.push(3i32)
    assert_eq(s.len(), 3usize, "three pushes => len 3")
    assert_eq(s.pop().unwrap_or(0i32), 3i32, "pop returns top")
    assert_eq(s.pop().unwrap_or(0i32), 2i32, "pop returns next")
    assert_eq(s.pop().unwrap_or(0i32), 1i32, "pop returns last")
    assert_true(s.is_empty(), "stack is empty after draining")
}

test "stack pop on empty returns null" {
    let s: Stack(i32) = stack(0)
    defer s.deinit()
    assert_true(s.pop().is_none(), "pop on empty stack is None")
}

test "stack peek does not remove" {
    let s: Stack(i32) = stack(0)
    defer s.deinit()
    s.push(10i32)
    s.push(20i32)
    assert_eq(s.peek().unwrap_or(0i32), 20i32, "peek returns top")
    assert_eq(s.len(), 2usize, "peek does not change len")
    assert_eq(s.pop().unwrap_or(0i32), 20i32, "top is still 20 after peek")
}

test "stack peek_ref mutates in place" {
    let s: Stack(i32) = stack(0)
    defer s.deinit()
    s.push(5i32)
    s.peek_ref() match {
        Some(p) => p.* = 42i32
        None => panic("peek_ref on non-empty stack should be Some")
    }
    assert_eq(s.pop().unwrap_or(0i32), 42i32, "mutation through peek_ref persists")
}

test "stack clear empties and the storage is reusable" {
    let s: Stack(i32) = stack(8)
    defer s.deinit()
    s.push(1i32)
    s.push(2i32)
    s.clear()
    assert_true(s.is_empty(), "cleared stack is empty")
    s.push(7i32)
    assert_eq(s.pop().unwrap_or(0i32), 7i32, "stack reused after clear")
}
