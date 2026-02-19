// Reference-counted smart pointer.
// Provides shared ownership of a heap-allocated value.
// The inner value is freed when the last Rc is released.

import std.allocator
import std.mem
import std.test

// Reference-counted pointer to a heap-allocated value of type T.
pub type Rc = struct(T) {
    ptr: &RcInner(T)?
    allocator: &Allocator?
}

// Internal control block: ref count + value, allocated on the heap.
type RcInner = struct(T) {
    ref_count: usize
    value: T
}

// Allocate an RcInner(T) on the heap using raw alloc + cast.
fn alloc_inner(value: $T, allocator: &Allocator) &RcInner(T) {
    const inner = allocator.new(RcInner(T))
    inner.ref_count = 1
    inner.value = value
    return inner
}

// Free an RcInner(T) through the allocator.
fn free_inner(inner: &RcInner($T), allocator: &Allocator) {
    allocator.free(inner)
}

// Create a new Rc wrapping the given value. Allocates an RcInner on the heap.
pub fn rc(value: $T, allocator: &Allocator? = null) Rc(T) {
    const alloc = allocator.or_global()
    const inner = alloc_inner(value, alloc)
    return .{ ptr = inner, allocator = allocator }
}

// Increment the reference count and return a new handle to the same value.
pub fn clone(self: &Rc($T)) Rc(T) {
    if self.ptr.is_none() {
        panic("Rc.clone: use after release")
    }
    self.ptr.value.ref_count = self.ptr.value.ref_count + 1
    return .{ ptr = self.ptr, allocator = self.allocator }
}

// Decrement the reference count. Frees the inner value when it reaches zero.
// Intended to be used with defer: `defer r.release()`
pub fn release(self: &Rc($T)) {
    if self.ptr.is_none() {
        return
    }

    let inner = self.ptr.value
    inner.ref_count = inner.ref_count - 1

    if inner.ref_count == 0 {
        free_inner(inner, self.allocator.or_global())
    }

    self.ptr = null
}

// Get a read-only reference to the inner value.
pub fn borrow(self: &Rc($T)) &T {
    if self.ptr.is_none() {
        panic("Rc.borrow: use after release")
    }
    // Compute pointer to value field: inner_ptr + offset_of(ref_count)
    let inner = self.ptr.value
    return (inner as &u8 + size_of(usize)) as &T
}

// Get a mutable reference to the inner value.
// Panics if ref_count > 1 (shared state must not be mutated).
pub fn borrow_mut(self: &Rc($T)) &T {
    if self.ptr.is_none() {
        panic("Rc.borrow_mut: use after release")
    }
    if self.ptr.value.ref_count > 1 {
        panic("Rc.borrow_mut: cannot mutate shared Rc (ref_count > 1)")
    }
    let inner = self.ptr.value
    return (inner as &u8 + size_of(usize)) as &T
}

// Return the current reference count. Returns 0 if released.
pub fn ref_count(self: &Rc($T)) usize {
    if self.ptr.is_none() {
        return 0
    }
    return self.ptr.value.ref_count
}

// Return true if this Rc has been released.
pub fn is_released(self: &Rc($T)) bool {
    return self.ptr.is_none()
}

// Assignment operator — currently a no-op stub.
// When the compiler supports op_assign, this will auto-clone on copy.
pub fn op_assign(lhs: &Rc($T), rhs: Rc(T)) {
    // TODO: implement when compiler supports op_assign
    // lhs.release()
    // lhs.ptr = rhs.ptr
    // lhs.allocator = rhs.allocator
    // if lhs.ptr.is_some() {
    //     lhs.ptr.value.ref_count = lhs.ptr.value.ref_count + 1
    // }
}

// =============================================================================
// Tests
// =============================================================================

test "rc create and borrow" {
    let r = rc(42i32)
    defer r.release()

    assert_eq(r.borrow().*, 42i32, "borrow should return inner value")
    assert_eq(r.ref_count(), 1usize, "initial ref_count should be 1")
}

test "rc clone increments ref_count" {
    let r = rc(10i32)
    defer r.release()

    let r2 = r.clone()
    defer r2.release()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2 after clone")
    assert_eq(r2.ref_count(), 2usize, "cloned ref_count should match")
    assert_eq(r2.borrow().*, 10i32, "cloned value should match")
}

test "rc release decrements ref_count" {
    let r = rc(99i32)
    let r2 = r.clone()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.release()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1 after release")
    assert_true(r2.is_released(), "r2 should be released")

    r.release()
    assert_true(r.is_released(), "r should be released")
}

test "rc release frees when last ref dropped" {
    let r = rc(123i32)
    let r2 = r.clone()
    let r3 = r.clone()

    assert_eq(r.ref_count(), 3usize, "ref_count should be 3")
    r3.release()
    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.release()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1")
    r.release()
    // All released, inner freed — no leak, no double free
}

test "rc borrow_mut works when sole owner" {
    let r = rc(5i32)
    defer r.release()

    r.borrow_mut().* = 42
    assert_eq(r.borrow().*, 42i32, "value should be mutated")
}

test "rc shared value visible through all handles" {
    let r = rc(0i32)
    defer r.release()

    let r2 = r.clone()
    defer r2.release()

    // Mutate through r (would need sole ownership, so release r2 first)
    r2.release()
    r.borrow_mut().* = 77

    // Re-clone and check
    let r3 = r.clone()
    defer r3.release()

    assert_eq(r3.borrow().*, 77i32, "cloned handle should see mutated value")
}

// Test helper type for struct tests
type RcTestPoint = struct { x: i32, y: i32 }

test "rc with struct value" {
    let r = rc(RcTestPoint { x = 3, y = 4 })
    defer r.release()

    assert_eq(r.borrow().x, 3i32, "x should be 3")
    assert_eq(r.borrow().y, 4i32, "y should be 4")

    let r2 = r.clone()
    defer r2.release()

    assert_eq(r2.borrow().x, 3i32, "cloned x should be 3")
}

test "rc with custom allocator" {
    let arena_state = arena_allocator(&global_allocator)
    let arena = arena_state.allocator()
    defer arena_state.deinit()

    let r = rc(42i32, &arena)
    defer r.release()

    assert_eq(r.borrow().*, 42i32, "value through arena allocator")
    assert_eq(r.ref_count(), 1usize, "ref_count with arena")
}

// Tests that motivate op_assign support — these test the DESIRED behavior
// once the compiler wires up op_assign for Rc. Until then, these use
// explicit clone/release.

// DESIRED: let r2 = r  →  auto-clones, bumps ref_count
// CURRENT: let r2 = r  →  byte copy, ref_count not bumped (WRONG)
// So for now we use r.clone() to get correct behavior.

test "rc clone via explicit clone (op_assign motivation)" {
    let r = rc(42i32)
    defer r.release()

    // DESIRED (once op_assign works):
    //   let r2 = r          // op_assign auto-clones
    //   defer r2.release()
    //   assert_eq(r.ref_count(), 2usize, "op_assign should bump ref_count")

    // CURRENT (explicit):
    let r2 = r.clone()
    defer r2.release()
    assert_eq(r.ref_count(), 2usize, "explicit clone should bump ref_count")
}
