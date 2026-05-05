// Owned(T) — value-by-value ownership with explicit transfer tracking.
//
// Pair with `defer buf.deinit()` to clean up on error and `buf.transfer()`
// to hand off on success — the transfer disarms the defer so the caller
// owns the value cleanly.
//
// Works for any T with `deinit(&T)` in scope: header-types like
// `StringBuilder` / `List` / `Dict` (cleanup is the type's own deinit), or
// raw heap pointers (cleanup is `mem.free` adapted to `fn(&&u8)`).

import std.option
import std.test

// `__value: T?` carries the ownership state inline:
// Some(_) = owned, None = transferred.
pub type Owned = struct(T) {
    __value: T?
    __cleanup: fn(&T) void
}

// Cleanup defaults to T.deinit. Works for any T with deinit(&T) in scope.
pub fn owned(value: $T) Owned(T) {
    return owned(value, deinit)
}

pub fn owned(value: $T, cleanup: fn(&T) void) Owned(T) {
    let some: T? = value
    return .{ __value = some, __cleanup = cleanup }
}

// Take the value out. Subsequent deinit is a no-op. Panics if already transferred.
pub fn transfer(self: &Owned($T)) T {
    let v = self.__value match {
        Some(v) => v,
        None => panic("Owned.transfer: value already transferred")
    }
    self.__value = None
    return v
}

// Run cleanup if still owned. Idempotent.
pub fn deinit(self: &Owned($T)) {
    self.__value match {
        Some(v) => {
            self.__cleanup(&v)
            self.__value = None
        },
        None => {}
    }
}

pub fn is_owned(self: &Owned($T)) bool {
    return self.__value.is_some()
}

// Field/method access through the wrapper: `pat_buf.append(...)` dispatches
// to StringBuilder.append. Returns a stable pointer into the inline payload —
// mutations through it persist (unlike a match-bound copy of the Some value).
//
// The pointer is computed by stepping past `Option`'s 4-byte tag plus padding
// for T's alignment. `__value` is the first field of `Owned`, so its offset
// is 0; the absolute offset reduces to the in-Option payload offset.
pub fn op_deref(self: &Owned($T)) &T {
    if self.__value.is_none() {
        panic("Owned.op_deref: value already transferred")
    }
    const tag_size: usize = 4
    let align = align_of(T)
    let payload_offset = (tag_size + align - 1) - (tag_size + align - 1) % align
    return ((self as &u8) + payload_offset) as &T
}

// =============================================================================
// Tests
// =============================================================================

type OwnedTestCounter = struct {
    count: i32
}

fn owned_test_bump(p: &OwnedTestCounter) {
    p.count = p.count + 1
}

test "owned deinit fires cleanup once" {
    let counter = OwnedTestCounter { count = 0 }
    let o = owned(&counter, fn(p: &&OwnedTestCounter) { p.*.count = p.*.count + 1 })
    assert_true(o.is_owned(), "fresh Owned should be owned")
    o.deinit()
    assert_eq(counter.count, 1i32, "cleanup should fire exactly once")
    assert_true(!o.is_owned(), "post-deinit should be empty")
}

test "owned deinit is idempotent" {
    let counter = OwnedTestCounter { count = 0 }
    let o = owned(&counter, fn(p: &&OwnedTestCounter) { p.*.count = p.*.count + 1 })
    o.deinit()
    o.deinit()
    o.deinit()
    assert_eq(counter.count, 1i32, "second/third deinit must be no-ops")
}

test "owned transfer disarms cleanup" {
    let counter = OwnedTestCounter { count = 0 }
    let o = owned(&counter, fn(p: &&OwnedTestCounter) { p.*.count = p.*.count + 1 })
    let taken = o.transfer()
    assert_true(taken == &counter, "transfer returns the wrapped value")
    assert_true(!o.is_owned(), "post-transfer should be empty")
    o.deinit()
    assert_eq(counter.count, 0i32, "cleanup must not fire after transfer")
}

test "owned defer + transfer disarms in success path" {
    let counter = OwnedTestCounter { count = 0 }
    {
        let o = owned(&counter, fn(p: &&OwnedTestCounter) { p.*.count = p.*.count + 1 })
        defer o.deinit()
        let taken = o.transfer()
        assert_true(taken == &counter, "transferred value matches")
    }
    assert_eq(counter.count, 0i32, "transfer disarms the deferred deinit")
}

test "owned defer fires when ? bails" {
    let counter = OwnedTestCounter { count = 0 }
    {
        let o = owned(&counter, fn(p: &&OwnedTestCounter) { p.*.count = p.*.count + 1 })
        defer o.deinit()
    }
    assert_eq(counter.count, 1i32, "defer fires the cleanup on early exit")
}
