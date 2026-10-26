// Heap memory as an owned resource (RFC-043), and moving values through a single slot.
//
// An allocator hands out a `Memory` and takes one back; nothing else creates or ends one. A slice
// is only ever a borrow: `as_slice` lends a block as elements of any type.

import core.panic
import core.rtti
import core.slice

import std.test

// `len` bytes at `ptr`, owned by whoever holds the value. The zero value, with a null `ptr`, was
// never allocated: it owns nothing and every allocator releases it as a no-op.
pub type Memory = struct {
    owned ptr: &u8
    len: usize
}

// Take ownership of `value` and release nothing. The end of every ownership chain: an allocator
// that has handed a block back to C, a region reclaiming a block it already owns, a handle whose
// resource left through a syscall.
#intrinsic
pub fn leak(value: move $T) {}

// Take ownership of `len` bytes at `ptr`: memory a foreign library handed over, or a block rebuilt
// from a pointer that was carried in its place.
pub fn from_raw(ptr: &u8, len: usize) Memory {
    return .{ ptr = ptr, len = len }
}

// The block that was never allocated: owns nothing, and every allocator releases it as a no-op.
pub fn unallocated() Memory {
    return .{ ptr = 0usize as &u8, len = 0 }
}

// Whether `m` holds a block, rather than being `unallocated()`.
pub fn is_allocated(m: &Memory) bool {
    return m.ptr != 0usize as &u8
}

// The block as `len / size_of(T)` elements of `T`, borrowed for as long as `m` is. Elements past
// what the owner initialized are uninitialized.
//
// Panics when the block's address is not aligned to `align_of(T)`.
#allow(W2004)
pub fn as_slice(m: &Memory) $T[] {
    if size_of(T) == 0 or m.len == 0 {
        return slice_from_raw_parts(m.ptr as &T, 0)
    }
    if (m.ptr as usize) % align_of(T) != 0 {
        panic("memory: slice of a block not aligned to its element type")
    }
    return slice_from_raw_parts(m.ptr as &T, m.len / size_of(T))
}

// =============================================================================
// Slots
// =============================================================================

// Exchanges the values in two slots. `&move` says the values leave their storage, so an owning `T`
// swaps with no copy and no second owner; the caller keeps both slots, each holding the other's
// value.
pub fn swap(a: &move $T, b: &move T) {
    let tmp = move a.*
    a.* = move b.*
    b.* = move tmp
}

// Puts `value` into the slot and hands back what was there. The caller names what goes in, so an
// owning type is never left holding a zeroed stand-in.
pub fn replace(slot: &move $T, value: move T) T {
    let old = move slot.*
    slot.* = move value
    return old
}

// Puts `value` into the slot and releases what was there: the assign-over-a-live-value the language
// refuses on its own (E2126), with the release the refusal is about.
pub fn install(slot: &move $T, value: move T) {
    let old = replace(slot, value)
    release(old)
}

test "a slice counts whole elements of the block" {
    let words = [0u32; 4]
    const slots: u32[] = words
    const m = from_raw(slots.ptr as &u8, 16)
    const xs: u32[] = m.as_slice()
    assert_eq(xs.len, 4 as usize, "sixteen bytes are four u32")
    const bytes: u8[] = m.as_slice()
    assert_eq(bytes.len, 16 as usize, "and sixteen u8")
    leak(m)
}

test "the unallocated block is an empty slice" {
    let m = unallocated()
    const xs: u64[] = m.as_slice()
    assert_eq(xs.len, 0 as usize, "nothing to slice")
    leak(m)
}
