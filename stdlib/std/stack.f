// LIFO stacks in two flavours, the managed and unmanaged split of spec §9.4, each a thin wrapper
// over the list of the matching flavour: `UnmanagedStack(T)` over `UnmanagedList(T)`, taking the
// allocator at every allocating call (`s.push(v, alloc)`), and `Stack(T)` with its allocator beside
// it (`s.push(v)`), reaching the storage through `op_deref`.
//
// Push/pop both act on the top of the stack; `peek` reads the top without removing it.

import std.allocator
import std.list
import std.option
import std.test

pub type UnmanagedStack = struct(T) {
    __inner: UnmanagedList(T)
}

pub type Stack = struct(T) {
    __storage: UnmanagedStack(T)
    allocator: &Allocator
}

// Reaches the storage: `s.len()`, `s.pop()` and every `UnmanagedStack` read resolve through this.
pub fn op_deref(self: &Stack($T)) &UnmanagedStack(T) {
    return &self.__storage
}

// Construct an empty unmanaged stack with room for `capacity` elements. Zero allocates nothing; a
// zero-initialised `UnmanagedStack` is the same empty stack.
pub fn unmanaged_stack(capacity: usize, allocator: &Allocator) UnmanagedStack($T) {
    return .{ __inner = unmanaged_list(capacity, allocator) }
}

// Construct an empty stack. The capacity hint pre-reserves storage to avoid early growth churn;
// pass 0 to defer allocation to the first `push`. `T` is inferred from the call's expected type
// (e.g. `let s: Stack(i32) = stack(0)` or `let s = stack(0); s.push(1i32)`).
//
// - `allocator`: kept for the stack's whole life. Null is the global allocator.
pub fn stack(capacity: usize, allocator: &Allocator? = null) Stack($T) {
    let out: Stack(T)
    out.allocator = allocator.unwrap_or(0usize as &Allocator)
    out.__storage = unmanaged_stack(capacity, out.allocator)
    return out
}

// =============================================================================
// UnmanagedStack: growth and release, allocator explicit
// =============================================================================

// Push a value onto the top of the stack. Grows the backing storage when capacity is exhausted.
pub fn push(self: &UnmanagedStack($T), value: T, allocator: &Allocator) {
    self.__inner.push(value, allocator)
}

// Free the backing storage. Each live element's `deinit()` runs first. Idempotent.
pub fn deinit(self: &UnmanagedStack($T), allocator: &Allocator) {
    self.__inner.deinit(allocator)
}

// =============================================================================
// UnmanagedStack: in-place mutation and reads
// =============================================================================

// Number of elements currently on the stack.
pub fn len(self: &UnmanagedStack($T)) usize {
    return self.__inner.len
}

// True when the stack holds no elements.
pub fn is_empty(self: &UnmanagedStack($T)) bool {
    return self.__inner.len == 0
}

// Remove and return the top element, or `null` when the stack is empty.
pub fn pop(self: &UnmanagedStack($T)) T? {
    return self.__inner.pop()
}

// Return the top element without removing it, or `null` when empty.
pub fn peek(self: &UnmanagedStack($T)) T? {
    return self.__inner.last()
}

// Return a pointer to the top element without removing it, or `null` when empty. Mutations through
// the pointer persist in the stack.
pub fn peek_ref(self: &UnmanagedStack($T)) &T? {
    if self.__inner.len == 0 {
        return null
    }
    return self.__inner.get_ref(self.__inner.len - 1)
}

// Drop every element, deiniting each. Backing storage is kept for reuse.
pub fn clear(self: &UnmanagedStack($T)) {
    self.__inner.clear()
}

// View the stack's storage as a slice in bottom-to-top order. Iterating the slice in reverse visits
// elements top-down.
pub fn as_slice(self: &UnmanagedStack($T)) T[] {
    return self.__inner.as_slice()
}

// Iterates the elements bottom to top, by value.
pub fn iter(self: &UnmanagedStack($T)) SliceIterator(T) {
    return self.__inner.iter()
}

// Iterates the elements top to bottom, by value: the order `pop` would yield them.
pub fn iter_rev(self: &UnmanagedStack($T)) SliceRevIterator(T) {
    return self.__inner.iter_rev()
}

// =============================================================================
// Stack: the managed API
// =============================================================================

// Push a value onto the top of the stack. Panics when the allocation fails.
pub fn push(self: &Stack($T), value: T) {
    self.__storage.push(value, self.allocator)
}

// Free the backing storage. Each live element's `deinit()` runs first. Idempotent.
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
