// Reference-counted smart pointer.
// Provides shared ownership of a heap-allocated value. The inner value is freed when the last Rc
// handle calls deinit().

import std.allocator
import std.atomic
import std.mem
import std.option
import std.test

// Reference-counted pointer to a heap-allocated value of type T. Each handle holds one count, so a
// handle is not copyable: a second one is `retain`, and each gives its count back in `deinit`.
pub type Rc = struct(T) {
    owned __inner: &RcInner(T)
    __allocator: &Allocator?
}

// Internal control block: ref count + value, allocated on the heap.
type RcInner = struct(T) {
    ref_count: usize
    value: T
}

// Create a new Rc wrapping the given value. Allocates an RcInner on the heap.
pub fn rc(value: move $T, allocator: &Allocator? = null) Rc(T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    inner.value = move value
    return .{ __inner = inner, __allocator = allocator }
}

// Allocate an Rc with zero-initialized value for in-place fill via op_deref.
pub fn rc_alloc(allocator: &Allocator? = null) Rc($T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    memset(inner as &u8, 0, size_of(RcInner(T)))
    inner.ref_count = 1
    return .{ __inner = inner, __allocator = allocator }
}

// Takes another count on the same value and returns the handle that holds it. `clone` on a handle
// is not this: it peels through `op_deref` to the value's own `clone`.
pub fn retain(self: &Rc($T)) Rc(T) {
    self.__inner.ref_count = self.__inner.ref_count + 1
    return .{ __inner = self.__inner, __allocator = self.__allocator }
}

// Gives this handle's count back, releasing the value and freeing the block with the last one.
pub fn deinit(self: move Rc($T)) {
    self.__inner.ref_count = self.__inner.ref_count - 1
    if self.__inner.ref_count == 0 {
        let val = move self.__inner.value
        release(val)
        self.__allocator.or_global().free(self.__inner)
    }
}

// Transparent access to the inner value via field syntax (e.g., rc.field).
pub fn op_deref(self: &Rc($T)) &T {
    return &self.__inner.value
}

// Returns how many handles hold the value.
pub fn ref_count(self: &Rc($T)) usize {
    return self.__inner.ref_count
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

test "rc retain increments ref_count" {
    let r = rc(10i32)
    defer r.deinit()

    let r2 = r.retain()
    defer r2.deinit()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2 after retain")
    assert_eq(r2.ref_count(), 2usize, "retained ref_count should match")
    assert_eq(r2.*, 10i32, "retained value should match")
}

test "rc deinit decrements ref_count" {
    let r = rc(99i32)
    let r2 = r.retain()

    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.deinit()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1 after deinit")
    r.deinit()
}

test "rc deinit frees when last ref dropped" {
    let r = rc(123i32)
    let r2 = r.retain()
    let r3 = r.retain()

    assert_eq(r.ref_count(), 3usize, "ref_count should be 3")
    r3.deinit()
    assert_eq(r.ref_count(), 2usize, "ref_count should be 2")
    r2.deinit()
    assert_eq(r.ref_count(), 1usize, "ref_count should be 1")
    r.deinit()
    // All deinit'd, inner freed - no leak, no double free
}

// Test helper type for struct tests
type RcTestPoint = struct { x: i32, y: i32 }
pub fn deinit(self: &RcTestPoint) {}

test "rc with struct value via op_deref" {
    let r = rc(RcTestPoint { x = 3, y = 4 })
    defer r.deinit()

    assert_eq(r.x, 3i32, "x should be 3")
    assert_eq(r.y, 4i32, "y should be 4")

    let r2 = r.retain()
    defer r2.deinit()

    assert_eq(r2.x, 3i32, "retained x should be 3")
}

test "rc with custom allocator" {
    let arena_state = arena_allocator(global())
    let arena = arena_state.allocator()
    defer arena_state.deinit()

    let r = rc(42i32, Some(&arena))
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
// Arc - Thread-safe reference counting (atomic operations)
// =============================================================================

// Atomically reference-counted pointer to a heap-allocated value of type T. Same control block as
// Rc, but retain/deinit use atomic operations on ref_count.
pub type Arc = struct(T) {
    owned __inner: &RcInner(T)
    __allocator: &Allocator?
}

// Create a new Arc wrapping the given value.
pub fn arc(value: move $T, allocator: &Allocator? = null) Arc(T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    inner.ref_count = 1
    inner.value = move value
    return .{ __inner = inner, __allocator = allocator }
}

// Allocate an Arc with zero-initialized value for in-place fill via op_deref.
pub fn arc_alloc(allocator: &Allocator? = null) Arc($T) {
    const alloc = allocator.or_global()
    const inner = alloc.new(RcInner(T))
    memset(inner as &u8, 0, size_of(RcInner(T)))
    inner.ref_count = 1
    return .{ __inner = inner, __allocator = allocator }
}

// Atomically takes another count on the same value and returns the handle that holds it.
pub fn retain(self: &Arc($T)) Arc(T) {
    __flang_atomic_add(&self.__inner.ref_count, 1usize)
    return .{ __inner = self.__inner, __allocator = self.__allocator }
}

// Atomically gives this handle's count back, releasing the value and freeing the block with the
// last one.
pub fn deinit(self: move Arc($T)) {
    const old = __flang_atomic_sub(&self.__inner.ref_count, 1usize)
    if old == 1 {
        let val = move self.__inner.value
        release(val)
        self.__allocator.or_global().free(self.__inner)
    }
}

// Transparent access to the inner value via field syntax.
pub fn op_deref(self: &Arc($T)) &T {
    return &self.__inner.value
}

// Returns how many handles hold the value (atomic load).
pub fn ref_count(self: &Arc($T)) usize {
    return __flang_atomic_load(&self.__inner.ref_count)
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

test "arc retain increments ref_count" {
    let a = arc(10i32)
    defer a.deinit()

    let a2 = a.retain()
    defer a2.deinit()

    assert_eq(a.ref_count(), 2usize, "arc ref_count should be 2 after retain")
    assert_eq(a2.ref_count(), 2usize, "arc retained ref_count should match")
    assert_eq(a2.*, 10i32, "arc retained value should match")
}

test "arc deinit decrements ref_count" {
    let a = arc(99i32)
    let a2 = a.retain()

    assert_eq(a.ref_count(), 2usize, "arc ref_count should be 2")
    a2.deinit()
    assert_eq(a.ref_count(), 1usize, "arc ref_count should be 1 after deinit")
    a.deinit()
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
