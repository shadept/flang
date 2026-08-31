// Testing utilities for FLang: the assertions a `test {}` block calls, and the tracking allocator
// the generated test runner installs for the duration of a run.

import std.allocator
import std.list
import std.mem
import std.string_builder

// =============================================================================
// TestAllocator - tracking allocator for leak detection in tests
// =============================================================================
//
// Forwards to malloc/realloc/free and reports every block to the ledger in the companion `test.c`,
// which is what knows how to report a leak and how to reset between tests. The split is where
// layout knowledge is: returning a `u8[]?` needs the FLang side, walking a list of live blocks does
// not.
//
// The runner installs this as the global allocator once, before the first test, so every
// `or_global()` in the code under test resolves to it without the test having to pass anything.

// The `void` returns are spelled out: a declaration with no return type followed by a `fn`
// declaration parses that `fn` as a function-type return (docs/known-issues.md).
#foreign fn __flang_test_track_alloc(ptr: &u8, size: usize) void
#foreign fn __flang_test_track_realloc(old_ptr: &u8, new_ptr: &u8, new_size: usize) void
#foreign fn __flang_test_track_free(ptr: &u8) void

// Built on malloc, so it carries the global allocator's ceiling: a request above `MAX_ALIGN` is
// declined rather than under-served.
fn test_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    if alignment > MAX_ALIGN {
        return null
    }
    const ptr = malloc(size)?
    __flang_test_track_alloc(ptr, size)
    // Wrapped explicitly - see the note in core/range.f::next.
    return Some(slice_from_raw_parts(ptr, size))
}

fn test_realloc(impl: &u8, memory: u8[], alignment: usize, new_size: usize) u8[]? {
    if alignment > MAX_ALIGN {
        return null
    }
    const old_ptr = memory.ptr
    const ptr = realloc(Some(old_ptr), new_size)?
    __flang_test_track_realloc(old_ptr, ptr, new_size)
    return Some(slice_from_raw_parts(ptr, new_size))
}

fn test_dealloc(impl: &u8, memory: u8[], alignment: usize) {
    __flang_test_track_free(memory.ptr)
    free(Some(memory.ptr))
}

// The ledger is in C and needs no per-instance state; the impl pointer addresses this and is never
// read.
type TestAllocatorState = struct {
    _unused: u8
}

const test_allocator_state = TestAllocatorState { _unused = 0 }

const test_allocator_vtable = AllocatorVTable {
    alloc = test_alloc,
    realloc = test_realloc,
    dealloc = test_dealloc,
}

const test_allocator = Allocator {
    impl = &test_allocator_state as &u8,
    vtable = &test_allocator_vtable,
}

// Called once by the generated test runner, after the constant initializers and before the first
// test. Not `pub`: lowering resolves it by name for the runner it emits, and there is no reason to
// call it by hand - a program that installs the tracking allocator outside a test run has no runner
// to report what it finds.
fn install_test_allocator() {
    const _prev = set_global_allocator(&test_allocator)
}

// Assert that a condition is true, panic with message if false
pub fn assert_true(condition: bool, msg: String) {
    if (condition == false) {
        panic(msg)
    }
}

// Assert that two values are equal
// NOTE: Uses == operator, so types must support equality comparison
pub fn assert_eq(a: $T, b: T, msg: String) {
    let equal: bool = a == b
    if (equal == false) {
        panic(msg)
    }
}

// Assert that two lists have the same elements in the same order. Uses == on each element pair.
pub fn assert_seq_eq(a: &List($T), b: &List(T), msg: String) {
    if a.len != b.len {
        let sb = string_builder(64)
        sb.append(msg)
        sb.append(": length mismatch (")
        sb.append(a.len as i64)
        sb.append(" vs ")
        sb.append(b.len as i64)
        sb.append(")")
        panic(sb.as_view())
    }
    for i in ..a.len {
        let eq: bool = a[i] == b[i]
        if eq == false {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element mismatch at index ")
            sb.append(i as i64)
            panic(sb.as_view())
        }
    }
}

// Assert that two lists have the same elements regardless of order. Uses == on elements. O(n^2) -
// intended for small test collections.
pub fn assert_set_eq(a: &List($T), b: &List(T), msg: String) {
    if a.len != b.len {
        let sb = string_builder(64)
        sb.append(msg)
        sb.append(": length mismatch (")
        sb.append(a.len as i64)
        sb.append(" vs ")
        sb.append(b.len as i64)
        sb.append(")")
        panic(sb.as_view())
    }

    // Check every element in a exists in b
    for i in ..a.len {
        let found = false
        for j in ..b.len {
            if a[i] == b[j] {
                found = true
                break
            }
        }
        if !found {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element at index ")
            sb.append(i as i64)
            sb.append(" in first not found in second")
            panic(sb.as_view())
        }
    }

    // Check every element in b exists in a
    for i in ..b.len {
        let found = false
        for j in ..a.len {
            if b[i] == a[j] {
                found = true
                break
            }
        }
        if !found {
            let sb = string_builder(64)
            sb.append(msg)
            sb.append(": element at index ")
            sb.append(i as i64)
            sb.append(" in second not found in first")
            panic(sb.as_view())
        }
    }
}

// NOTE: assert_ok and assert_err are in std/result.f to avoid circular imports
