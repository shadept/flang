// Reference-counted smart pointer.
// Provides shared ownership of a heap-allocated value.
// The inner value is freed when the last Rc handle calls deinit().

import std.allocator
import std.atomic
import std.mem
import std.test

// Reference-counted pointer to a heap-allocated value of type T.
pub type Rc = struct(T) {
    __inner: &RcInner(T)?
    __allocator: &Allocator?
}

// Internal control block: ref count + value, allocated on the heap.
type RcInner = struct(T) {
    ref_count: usize
    value: T
}

// Create a new Rc wrapping the given value. Allocates an RcInner on the heap.
pub fn rc(value: $T, allocator: &Allocator? = null) Rc(T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    inner.value = value
    return .{ __inner = inner, __allocator = alloc }
}

// Allocate an Rc with zero-initialized value for in-place fill via op_deref.
pub fn rc_alloc(allocator: &Allocator? = null) Rc($T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    return .{ __inner = inner, __allocator = alloc }
}

// Increment the reference count and return a new handle to the same value.
pub fn clone(self: &Rc($T)) Rc(T) {
    const inner = self.__inner match {
        Some(p) => p,
        None => panic("Rc.clone: use after deinit")
    }
    inner.ref_count = inner.ref_count + 1
    return .{ __inner = self.__inner, __allocator = self.__allocator }
}

// Decrement the reference count. Frees the inner value when it reaches zero.
// Calls T.deinit() before freeing (statically dispatched via monomorphization).
pub fn deinit(self: &Rc($T)) {
    let inner = self.__inner match {
        Some(p) => p,
        None => return
    }
    inner.ref_count = inner.ref_count - 1

    if inner.ref_count == 0 {
        let val_ptr: &T = (inner as &u8 + size_of(usize)) as &T
        val_ptr.deinit()
        self.__allocator.or_global().free(inner)
    }

    self.__inner = null
}

// Transparent access to the inner value via field syntax (e.g., rc.field).
pub fn op_deref(self: &Rc($T)) &T {
    const inner = self.__inner match {
        Some(p) => p,
        None => panic("Rc.op_deref: use after deinit")
    }
    return (inner as &u8 + size_of(usize)) as &T
}

// Return the current reference count. Returns 0 if deinit'd.
pub fn ref_count(self: &Rc($T)) usize {
    return self.__inner match {
        Some(p) => p.ref_count,
        None => 0
    }
}

// Return true if this Rc has been deinit'd.
pub fn is_released(self: &Rc($T)) bool {
    return self.__inner.is_none()
}

// =============================================================================
// Tests
// =============================================================================

test "rc create and op_deref" {
    let r = rc(42i32)
    defer r.deinit()

    assert_eq(r.*, 42i32, "op_deref should return inner value")
    assert_eq(r.ref_count(), 1usize, "initial ref_count should be 1")
}

test "rc clone increments ref_count" {
    let r = rc(10i32)
    defer r.deinit()

    let r2 = r.clone()
    defer r2.deinit()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2 after clone")
    assert_eq(r2.ref_count(), 2usize, "cloned ref_count should match")
    assert_eq(r2.*, 10i32, "cloned value should match")
}

test "rc deinit decrements ref_count" {
    let r = rc(99i32)
    let r2 = r.clone()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.deinit()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1 after deinit")
    assert_true(r2.is_released(), "r2 should be released")

    r.deinit()
    assert_true(r.is_released(), "r should be released")
}

test "rc deinit frees when last ref dropped" {
    let r = rc(123i32)
    let r2 = r.clone()
    let r3 = r.clone()

    assert_eq(r.ref_count(), 3usize, "ref_count should be 3")
    r3.deinit()
    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.deinit()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1")
    r.deinit()
    // All deinit'd, inner freed — no leak, no double free
}

// Test helper type for struct tests
type RcTestPoint = struct { x: i32, y: i32 }

test "rc with struct value via op_deref" {
    let r = rc(RcTestPoint { x = 3, y = 4 })
    defer r.deinit()

    assert_eq(r.x, 3i32, "x should be 3")
    assert_eq(r.y, 4i32, "y should be 4")

    let r2 = r.clone()
    defer r2.deinit()

    assert_eq(r2.x, 3i32, "cloned x should be 3")
}

test "rc with custom allocator" {
    let arena_state = arena_allocator(&global_allocator)
    let arena = arena_state.allocator()
    defer arena_state.deinit()

    let r = rc(42i32, &arena)
    defer r.deinit()

    assert_eq(r.*, 42i32, "value through arena allocator")
    assert_eq(r.ref_count(), 1usize, "ref_count with arena")
}

test "rc mutate through op_deref" {
    let r = rc(5i32)
    defer r.deinit()

    let ptr: &i32 = r.op_deref()
    ptr.* = 42
    assert_eq(r.*, 42i32, "value should be mutated through op_deref")
}

test "rc_alloc zero-initialized" {
    let r: Rc(i32) = rc_alloc()
    defer r.deinit()

    assert_eq(r.*, 0i32, "rc_alloc should zero-initialize")
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1")
}

// =============================================================================
// Arc — Thread-safe reference counting (atomic operations)
// =============================================================================

// Atomically reference-counted pointer to a heap-allocated value of type T.
// Same control block as Rc, but clone/deinit use atomic operations on ref_count.
pub type Arc = struct(T) {
    __inner: &RcInner(T)?
    __allocator: &Allocator?
}

// Create a new Arc wrapping the given value.
pub fn arc(value: $T, allocator: &Allocator? = null) Arc(T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    inner.value = value
    return .{ __inner = inner, __allocator = alloc }
}

// Allocate an Arc with zero-initialized value for in-place fill via op_deref.
pub fn arc_alloc(allocator: &Allocator? = null) Arc($T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    return .{ __inner = inner, __allocator = alloc }
}

// Atomically increment the reference count and return a new handle.
pub fn clone(self: &Arc($T)) Arc(T) {
    const inner = self.__inner match {
        Some(p) => p,
        None => panic("Arc.clone: use after deinit")
    }
    __flang_atomic_add(&inner.ref_count, 1usize)
    return .{ __inner = self.__inner, __allocator = self.__allocator }
}

// Atomically decrement the reference count. Frees when it reaches zero.
pub fn deinit(self: &Arc($T)) {
    let inner = self.__inner match {
        Some(p) => p,
        None => return
    }
    let old = __flang_atomic_sub(&inner.ref_count, 1usize)

    if old == 1 {
        let val_ptr: &T = (inner as &u8 + size_of(usize)) as &T
        val_ptr.deinit()
        self.__allocator.or_global().free(inner)
    }

    self.__inner = null
}

// Transparent access to the inner value via field syntax.
pub fn op_deref(self: &Arc($T)) &T {
    const inner = self.__inner match {
        Some(p) => p,
        None => panic("Arc.op_deref: use after deinit")
    }
    return (inner as &u8 + size_of(usize)) as &T
}

// Return the current reference count (atomic load). Returns 0 if deinit'd.
pub fn ref_count(self: &Arc($T)) usize {
    return self.__inner match {
        Some(p) => __flang_atomic_load(&p.ref_count),
        None => 0
    }
}

// Return true if this Arc has been deinit'd.
pub fn is_released(self: &Arc($T)) bool {
    return self.__inner.is_none()
}

// =============================================================================
// Arc Tests
// =============================================================================

test "arc create and op_deref" {
    let a = arc(42i32)
    defer a.deinit()

    assert_eq(a.*, 42i32, "arc op_deref should return inner value")
    assert_eq(a.ref_count(), 1usize, "arc initial ref_count should be 1")
}

test "arc clone increments ref_count" {
    let a = arc(10i32)
    defer a.deinit()

    let a2 = a.clone()
    defer a2.deinit()

    assert_eq(a.ref_count(), 2usize, "arc ref_count should be 2 after clone")
    assert_eq(a2.ref_count(), 2usize, "arc cloned ref_count should match")
    assert_eq(a2.*, 10i32, "arc cloned value should match")
}

test "arc deinit decrements ref_count" {
    let a = arc(99i32)
    let a2 = a.clone()

    assert_eq(a.ref_count(), 2usize, "arc ref_count should be 2")
    a2.deinit()
    assert_eq(a.ref_count(), 1usize, "arc ref_count should be 1 after deinit")
    assert_true(a2.is_released(), "arc a2 should be released")

    a.deinit()
    assert_true(a.is_released(), "arc a should be released")
}

test "arc with struct value via op_deref" {
    let a = arc(RcTestPoint { x = 7, y = 8 })
    defer a.deinit()

    assert_eq(a.x, 7i32, "arc x should be 7")
    assert_eq(a.y, 8i32, "arc y should be 8")
}

test "arc_alloc zero-initialized" {
    let a: Arc(i32) = arc_alloc()
    defer a.deinit()

    assert_eq(a.*, 0i32, "arc_alloc should zero-initialize")
    assert_eq(a.ref_count(), 1usize, "arc ref_count should be 1")
}
