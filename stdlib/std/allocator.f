// Generic allocator abstraction with vtable-based polymorphism.

import core.panic
import core.rtti

import std.mem
import std.option


pub fn or_global(alloc: &Allocator?) &Allocator {
    #if(runtime.testing) {
        return alloc.unwrap_or(&test_allocator)
    }
    return alloc.unwrap_or(&global_allocator)
}

// =============================================================================
// Allocator - interface for memory management
// =============================================================================

// Function type definitions for the allocator vtable.
pub type AllocatorVTable = struct {
    alloc: fn(&u8, size: usize, alignment: usize) u8[]?
    realloc: fn(&u8, memory: u8[], new_size: usize) u8[]?
    dealloc: fn(&u8, memory: u8[]) void
}

// Type-erased allocator interface.
// impl: pointer to allocator-specific state (cast to &u8 for type erasure)
// vtable: pointer to function table
pub type Allocator = struct {
    impl: &u8,
    vtable: &AllocatorVTable
}

// Allocate `size` bytes with given `alignment`.
// Returns pointer to allocated memory or null on failure.
pub fn alloc(allocator: &Allocator, size: usize, alignment: usize) u8[]? {
    return allocator.vtable.alloc(allocator.impl, size, alignment)
}

// Reallocate an existing allocation to a new size.
// Returns new pointer or null on failure.
// Some allocators may not support realloc and return null.
pub fn realloc(allocator: &Allocator, memory: u8[], new_size: usize) u8[]? {
    return allocator.vtable.realloc(allocator.impl, memory, new_size)
}

// Free memory previously allocated by this allocator.
// Some allocators (like FixedBufferAllocator) may do nothing.
pub fn dealloc(allocator: &Allocator, memory: u8[]) {
    allocator.vtable.dealloc(allocator.impl, memory)
}

pub fn new(allocator: &Allocator, ty: Type($T)) &T {
    const buffer = allocator.alloc(ty.size, ty.align)
    if buffer.is_none() {
        panic("Unable to allocate")
    }
    return buffer.unwrap().ptr as &T
}

// Allocate a slot for `T` and copy `value` into it. Returns a reference
// to the heap-allocated value.
#inline pub fn box(allocator: &Allocator, value: $T) &T {
    const ptr = allocator.new(Type(T))
    ptr.* = value
    return ptr
}

pub fn free(allocator: &Allocator, value: &$T) {
    const slice = slice_from_raw_parts(value as &u8, size_of(T))
    allocator.dealloc(slice)
}

// Free a typed slice. The slice's `len` is taken as the count of T
// elements to release (use the slice's full backing extent — for a
// `List`/`Dict` buffer that means slicing over `cap`, not `len`).
// No-op on empty slices so callers don't need a guard.
pub fn free(allocator: &Allocator, items: $T[]) {
    if items.len == 0 { return }
    const bytes = slice_from_raw_parts(items.ptr as &u8, items.len * size_of(T))
    allocator.dealloc(bytes)
}

// =============================================================================
// GlobalAllocator - wraps malloc/free from std.mem
// =============================================================================

// GlobalAllocator has no state; we use a dummy struct for the impl pointer.
pub type GlobalAllocatorState = struct {
    _unused: u8
}

fn global_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    // malloc typically returns suitably aligned memory for any type.
    // For now we ignore alignment and rely on malloc's default alignment.
    return slice_from_raw_parts(malloc(size)?, size)
}

fn global_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    return slice_from_raw_parts(realloc(memory.ptr, new_size)?, new_size)
}

fn global_dealloc(impl: &u8, memory: u8[]) {
    free(memory.ptr)
}

// VTable instance for GlobalAllocator
const global_allocator_vtable = AllocatorVTable {
    alloc = global_alloc,
    realloc = global_realloc,
    dealloc = global_dealloc
}

// Singleton state for GlobalAllocator (no actual state needed)
const global_allocator_state = GlobalAllocatorState { _unused = 0 }
pub const global_allocator = Allocator {
    impl = &global_allocator_state as &u8,
    vtable = &global_allocator_vtable
}

// =============================================================================
// TestAllocator - tracking allocator for leak detection in tests
// =============================================================================
// Wraps malloc/free but records every live allocation in an intrusive linked
// list (itself allocated via raw malloc so it never recurses through or_global).
// At the end of a test, call check_leaks() to print any un-freed allocations,
// then deinit() to tear down the tracker and free all remaining memory.

// Linked-list node tracking a single live allocation.
// Allocated via raw malloc — never goes through the Allocator interface.
type TestAllocEntry = struct {
    ptr: &u8
    size: usize
    next: &TestAllocEntry?
}

pub type TestAllocatorState = struct {
    head: &TestAllocEntry?
    alloc_count: usize
    dealloc_count: usize
    total_bytes: usize
}

fn test_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    let state = impl as &TestAllocatorState
    const ptr = malloc(size)
    if ptr.is_none() {
        return null
    }

    // Record this allocation in the tracking list
    const entry_raw = malloc(size_of(TestAllocEntry))
    if entry_raw.is_some() {
        const entry = entry_raw.unwrap() as &TestAllocEntry
        entry.ptr = ptr.unwrap()
        entry.size = size
        entry.next = state.head
        state.head = entry
    }

    state.alloc_count = state.alloc_count + 1
    state.total_bytes = state.total_bytes + size

    return slice_from_raw_parts(ptr.unwrap(), size)
}

fn test_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    let state = impl as &TestAllocatorState
    const old_ptr = memory.ptr
    const old_size = memory.len
    const ptr = realloc(old_ptr, new_size)
    if ptr.is_none() {
        return null
    }

    // Update the tracking entry for this pointer
    let entry = state.head
    while entry.is_some() {
        let e = entry.unwrap()
        if e.ptr as usize == old_ptr as usize {
            e.ptr = ptr.unwrap()
            e.size = new_size
            break
        }
        entry = e.next
    }

    state.total_bytes = state.total_bytes - old_size + new_size

    return slice_from_raw_parts(ptr.unwrap(), new_size)
}

fn test_dealloc(impl: &u8, memory: u8[]) {
    let state = impl as &TestAllocatorState
    const target = memory.ptr as usize

    // Remove from tracking list
    let prev: &TestAllocEntry? = null
    let entry = state.head
    while entry.is_some() {
        let e = entry.unwrap()
        if e.ptr as usize == target {
            // Unlink
            prev match {
                Some(p) => { p.next = e.next },
                None => { state.head = e.next }
            }
            state.total_bytes = state.total_bytes - e.size
            free(e as &u8)
            break
        }
        prev = entry
        entry = e.next
    }

    state.dealloc_count = state.dealloc_count + 1
    free(memory.ptr)
}

// Returns the number of live (leaked) allocations.
pub fn check_leaks(state: &TestAllocatorState) usize {
    let count: usize = 0
    let leaked_bytes: usize = 0
    let entry = state.head
    while entry.is_some() {
        let e = entry.unwrap()
        count = count + 1
        leaked_bytes = leaked_bytes + e.size
        print("  leak: address=")
        println(e.ptr as usize)
        print(" size=")
        println(e.size)
        entry = e.next
    }
    if count > 0 {
        print("test allocator: leaked allocations=")
        println(count)
        print(" bytes=")
        println(leaked_bytes)
    }
    return count
}

// Free all remaining tracked allocations and the tracking nodes themselves.
pub fn deinit(state: &TestAllocatorState) {
    let entry = state.head
    while entry.is_some() {
        let e = entry.unwrap()
        let next = e.next
        free(e.ptr)
        free(e as &u8)
        entry = next
    }
    state.head = null
    state.alloc_count = 0
    state.dealloc_count = 0
    state.total_bytes = 0
}

const test_allocator_vtable = AllocatorVTable {
    alloc = test_alloc,
    realloc = test_realloc,
    dealloc = test_dealloc
}

pub const test_allocator_state = TestAllocatorState {
    head = null,
    alloc_count = 0,
    dealloc_count = 0,
    total_bytes = 0
}

pub const test_allocator = Allocator {
    impl = &test_allocator_state as &u8,
    vtable = &test_allocator_vtable
}

// =============================================================================
// FixedBufferAllocator - bump allocator over a provided buffer
// =============================================================================

// State for the fixed buffer allocator.
// Tracks the buffer, its size, and current allocation offset.
pub type FixedBufferAllocatorState = struct {
    buffer: u8[],
    offset: usize
}

// Align a value up to the given alignment.
// alignment must be a power of 2.
// TODO: Needs bitwise AND operator to implement properly.
//   Correct implementation: return (value + mask) & (0 - alignment)
fn align_up(value: usize, alignment: usize) usize {
    let mask = alignment - 1
    return value + mask - (value + mask) % alignment
}

fn fixed_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    let state = impl as &FixedBufferAllocatorState

    // Align current offset
    let aligned_offset = align_up(state.offset, alignment)

    // Check if we have enough space
    let end_offset = aligned_offset + size
    if end_offset > state.buffer.len {
        return null
    }

    // Bump the offset
    let new_memory = state.buffer[aligned_offset..end_offset]
    state.offset = end_offset

    return new_memory
}

fn fixed_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    let state = impl as &FixedBufferAllocatorState

    // If memory is empty, treat as fresh allocation
    if memory.len == 0 {
        return fixed_alloc(impl, new_size, 1)
    }

    // Check if this is the most recent allocation (can extend in place)
    let mem_start = memory.ptr as usize
    let mem_end = mem_start + memory.len
    let buf_start = state.buffer.ptr as usize
    let current_end = buf_start + state.offset

    if mem_end == current_end {
        // This is the last allocation, try to extend
        let new_end = mem_start + new_size
        let buf_end = buf_start + state.buffer.len
        if (new_end <= buf_end) {
            // Can extend in place
            state.offset = new_end - buf_start
            return slice_from_raw_parts(memory.ptr, new_size)
        }
    }

    // Cannot extend in place - allocate new and copy
    let new_mem = fixed_alloc(impl, new_size, 1)?

    // Copy old data
    let copy_size = if memory.len < new_size { memory.len } else { new_size }
    memcpy(new_mem.ptr, memory.ptr, copy_size)
    return new_mem
}

fn fixed_dealloc(impl: &u8, memory: u8[]) {
    // FixedBufferAllocator does not support individual frees.
    // Memory is reclaimed by resetting the allocator.
}

// VTable instance for FixedBufferAllocator
const fixed_buffer_allocator_vtable = AllocatorVTable {
    alloc = fixed_alloc,
    realloc = fixed_realloc,
    dealloc = fixed_dealloc
}

// Initialize a FixedBufferAllocator from a pre-allocated buffer.
// This allocator should not outlive the provided buffer.
pub fn fixed_buffer_allocator(buffer: u8[]) FixedBufferAllocatorState {
    return .{
        buffer = buffer,
        offset = 0
    }
}

pub fn allocator(state: &FixedBufferAllocatorState) Allocator {
    return Allocator {
        impl = state as &u8,
        vtable = &fixed_buffer_allocator_vtable
    }
}

// Reset a FixedBufferAllocator to reuse its buffer from the beginning.
pub fn reset(state: &FixedBufferAllocatorState) {
    state.offset = 0
}

// =============================================================================
// ArenaAllocator - page-based bump allocator with bulk teardown
// =============================================================================
// Arena semantics: bump-allocate within pages, no individual free,
// bulk teardown via reset()/deinit(). Composable with any backing allocator.

// Intrusive linked list header at the start of each page.
// Page layout in memory: [ArenaPage header | usable bytes...]
type ArenaPage = struct {
    next: &ArenaPage?,
    size: usize,
    offset: usize
}

pub type ArenaAllocator = struct {
    backing: &Allocator,
    page_size: usize,
    first_page: &ArenaPage?,
    current_page: &ArenaPage?
}

pub const DEFAULT_ARENA_PAGE_SIZE: usize = 4096

fn arena_new_page(state: &ArenaAllocator, min_size: usize) &ArenaPage? {
    const header_size = size_of(ArenaPage)
    const needed = min_size + header_size
    const total = align_up(needed, state.page_size)

    const raw = state.backing.alloc(total, 8)?
    const page = raw.ptr as &ArenaPage
    page.next = null
    page.size = total - header_size
    page.offset = 0

    // Link into chain
    state.current_page match {
        Some(cp) => { cp.next = page },
        None => {}
    }
    if state.first_page.is_none() {
        state.first_page = page
    }
    state.current_page = page

    return page
}

fn arena_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    let state = impl as &ArenaAllocator
    const header_size = size_of(ArenaPage)

    // Try current page first
    if state.current_page.is_some() {
        let page = state.current_page.unwrap()
        let aligned_offset = align_up(page.offset, alignment)

        if aligned_offset + size <= page.size {
            // Compute pointer: page base + header + aligned offset
            let base = page as &u8
            let ptr = (base as usize + header_size + aligned_offset) as &u8
            page.offset = aligned_offset + size
            return slice_from_raw_parts(ptr, size)
        }
    }

    // Current page doesn't fit — allocate a new page
    let new_page = arena_new_page(state, size)
    if new_page.is_none() {
        return null
    }

    let page = new_page.unwrap()
    let aligned_offset = align_up(0, alignment)
    let base = page as &u8
    let ptr = (base as usize + header_size + aligned_offset) as &u8
    page.offset = aligned_offset + size
    return slice_from_raw_parts(ptr, size)
}

fn arena_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    // Allocate new, copy old data
    let new_mem = arena_alloc(impl, new_size, 1)
    if new_mem.is_none() {
        return null
    }

    let copy_size = if memory.len < new_size { memory.len } else { new_size }
    if copy_size > 0 {
        memcpy(new_mem.unwrap().ptr, memory.ptr, copy_size)
    }
    return new_mem
}

fn arena_dealloc(impl: &u8, memory: u8[]) {
    // Arena does not support individual frees — no-op.
}

const arena_allocator_vtable = AllocatorVTable {
    alloc = arena_alloc,
    realloc = arena_realloc,
    dealloc = arena_dealloc
}

// Create an arena allocator backed by the given allocator.
pub fn arena_allocator(backing: &Allocator, page_size: usize = 4096) ArenaAllocator {
    return .{
        backing = backing,
        page_size = page_size,
        first_page = null,
        current_page = null
    }
}

// Free all pages through the backing allocator.
pub fn deinit(state: &ArenaAllocator) {
    const header_size = size_of(ArenaPage)
    let page = state.first_page
    while page.is_some() {
        let p = page.unwrap()
        let next = p.next
        let total = p.size + header_size
        let raw = slice_from_raw_parts(p as &u8, total)
        state.backing.dealloc(raw)
        page = next
    }
    state.first_page = null
    state.current_page = null
}

// Reset all pages to offset 0 — keeps pages allocated for reuse.
pub fn reset(state: &ArenaAllocator) {
    let page = state.first_page
    while page.is_some() {
        let p = page.unwrap()
        p.offset = 0
        page = p.next
    }
    state.current_page = state.first_page
}

pub fn allocator(state: &ArenaAllocator) Allocator {
    return Allocator {
        impl = state as &u8,
        vtable = &arena_allocator_vtable
    }
}
