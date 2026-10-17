// Testing utilities for FLang: the assertions a `test {}` block calls, and the context the
// generated test runner runs each test under.

import std.allocator
import std.collections.list
import std.mem

// =============================================================================
// TestAllocator - tracking allocator for leak detection in tests
// =============================================================================
//
// Forwards to malloc/realloc/free and reports every block to the ledger in the companion `test.c`,
// which is what knows how to report a leak and how to reset between tests. The split is where
// layout knowledge is: returning a `u8[]?` needs the FLang side, walking a list of live blocks does
// not.
//
// Each test runs with this as `context.allocator` (`run_test`), so every allocation the code under
// test makes without naming an allocator is tracked.

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

// Every test's `context.temp_allocator`: reset before each test, so what one test left behind is
// reclaimed, and never reported.
const test_temp = arena_allocator(context.allocator)
const test_temp_allocator = allocator(&test_temp)

// Runs one test under its context: the tracking allocator and a fresh temp arena. The generated
// runner calls it for each test, inside the test's recovery point; a test that panics skips nothing
// here, since the arena is reset on the way in. Not `pub`: lowering resolves it by name for the
// runner it emits.
#intrinsic
fn run_test(body: fn()) {
    let temp = &test_temp
    temp.reset()
    context(allocator = &test_allocator, temp_allocator = &test_temp_allocator) {
        body()
    }
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

test "a test runs under the tracking allocator, with its own temp arena" {
    assert_true(context.allocator.impl == (&test_allocator).impl, "allocations are tracked")
    const served = context.temp_allocator.alloc(256, 8) match {
        Some(block) => block.len
        None => 0usize
    }
    assert_true(served == 256usize, "the arena serves temp allocations, never freed")
}
