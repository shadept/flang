// Generic LIFO stack — thin convenience wrapper over `List(T)`.
//
// Push/pop both act on the top of the stack; `peek` reads the top
// without removing it. The underlying `List(T)` owns the backing
// storage.

import std.allocator
import std.list
import std.option
import std.test

pub type Stack = struct(T) {
    inner: List(T)
}

// Construct an empty stack. The capacity hint pre-reserves storage to
// avoid early growth churn; pass 0 to defer allocation to the first
// `push`. `T` is inferred from the call's expected type (e.g.
// `let s: Stack(i32) = stack(0)` or `let s = stack(0); s.push(1i32)`).
pub fn stack(capacity: usize, allocator: &Allocator? = null) Stack($T) {
    return .{ inner = list(capacity, allocator) }
}

// Free the backing storage. Each live element's `deinit()` runs first.
// The stack should not be used after this.
pub fn deinit(self: &Stack($T)) {
    self.inner.deinit()
}

// Number of elements currently on the stack.
pub fn len(self: Stack($T)) usize {
    return self.inner.len
}

// True when the stack holds no elements.
pub fn is_empty(self: Stack($T)) bool {
    return self.inner.len == 0
}

// Push a value onto the top of the stack. Grows the backing storage
// when capacity is exhausted.
pub fn push(self: &Stack($T), value: T) {
    self.inner.push(value)
}

// Remove and return the top element, or `null` when the stack is empty.
pub fn pop(self: &Stack($T)) T? {
    return self.inner.pop()
}

// Return the top element without removing it, or `null` when empty.
pub fn peek(self: Stack($T)) T? {
    if self.inner.len == 0 { return null }
    return self.inner.get(self.inner.len - 1)
}

// Return a pointer to the top element without removing it, or `null`
// when empty. Mutations through the pointer persist in the stack.
pub fn peek_ref(self: &Stack($T)) &T? {
    if self.inner.len == 0 { return null }
    return self.inner.get_ref(self.inner.len - 1)
}

// Drop every element. Backing storage is retained so subsequent pushes
// reuse it. Element `deinit()` is NOT called — clear is a fast reset,
// not a full release. Use `deinit()` followed by a fresh `stack(...)`
// when elements own heap.
pub fn clear(self: &Stack($T)) {
    self.inner.clear()
}

// View the stack's storage as a slice in bottom-to-top order.
// Iterating the slice in reverse visits elements top-down.
pub fn as_slice(self: Stack($T)) T[] {
    return self.inner.as_slice()
}

// =============================================================================
// Tests
// =============================================================================

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
        Some(p) => p.* = 42i32,
        None => panic("peek_ref on non-empty stack should be Some")
    }
    assert_eq(s.pop().unwrap_or(0i32), 42i32, "mutation through peek_ref persists")
}

test "stack clear empties without deinit" {
    let s: Stack(i32) = stack(8)
    defer s.deinit()
    s.push(1i32)
    s.push(2i32)
    s.clear()
    assert_true(s.is_empty(), "cleared stack is empty")
    s.push(7i32)
    assert_eq(s.pop().unwrap_or(0i32), 7i32, "stack reused after clear")
}
