//! TEST: sb_to_string_transfers_ownership
//! EXIT: 0

// Verifies StringBuilder.to_string() transfers buffer ownership to OwnedString
// without allocating or copying. The SB's cap/len/ptr are all zeroed so a
// subsequent deinit() is a no-op.

import std.string_builder
import std.string
import std.allocator

pub fn main() i32 {
    let sb = string_builder(32)

    sb.append("hello, world")
    const sb_ptr_before = sb.ptr as usize
    const sb_len_before = sb.len
    if sb_ptr_before == 0 { return 1 }
    if sb_len_before != 12 { return 2 }

    const owned = sb.to_string()

    // After transfer: sb is empty and its buffer pointer has been zeroed.
    if sb.cap != 0 { return 10 }
    if sb.len != 0 { return 11 }
    const sb_ptr_after = sb.ptr as usize
    if sb_ptr_after != 0 { return 12 }

    // OwnedString now owns the original buffer.
    const owned_ptr = owned.ptr as usize
    if owned_ptr != sb_ptr_before { return 20 }
    if owned.len != sb_len_before { return 21 }

    const view = owned.as_view()
    if view.len != 12 { return 30 }
    for i in 0..view.len {
        if view[i] != "hello, world"[i] { return 31 }
    }

    // Null terminator at owned.ptr + owned.len must be 0.
    const term = owned.ptr + owned.len
    if term.* != 0u8 { return 40 }

    // Clean up.
    let m = owned
    m.deinit()

    // SB had its buffer transferred, so deinit must be a no-op (no double free).
    sb.deinit()

    return 0
}
