// Generic allocator abstraction with vtable-based polymorphism.

import core.panic
import core.rtti

import std.mem
import std.option

// =============================================================================
// Allocator - interface for memory management
// =============================================================================

// Function type definitions for the allocator vtable.
pub type AllocatorVTable = struct {
    alloc: fn(&u8, size: usize, alignment: usize) u8[]?
    realloc: fn(&u8, memory: u8[], new_size: usize) u8[]?
    free: fn(&u8, memory: u8[]) void
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
pub fn free(allocator: &Allocator, memory: u8[]) {
    allocator.vtable.free(allocator.impl, memory)
}

pub fn new(allocator: &Allocator, type: Type($T)) &T {
    const buffer = allocator.alloc(type.size, type.align)
    if (buffer.is_none()) {
        panic("Unable to allocate")
    }
    return buffer.value.ptr as &T
}

pub fn delete(allocator: &Allocator, value: &$T) {
    const slice = slice_from_raw_parts(value as &u8, size_of(T))
    allocator.free(slice)
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
    const ptr = malloc(size)
    if (ptr.is_none()) {
        return null
    }
    return slice_from_raw_parts(ptr.value, size)
}

fn global_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    const ptr = realloc(memory.ptr, new_size)
    if (ptr.is_none()) {
        return null
    }

    return slice_from_raw_parts(ptr.value, new_size)
}

fn global_free(impl: &u8, memory: u8[]) {
    free(memory.ptr)
}

// VTable instance for GlobalAllocator
const global_allocator_vtable = AllocatorVTable {
    alloc = global_alloc,
    realloc = global_realloc,
    free = global_free
}

// Singleton state for GlobalAllocator (no actual state needed)
const global_allocator_state = GlobalAllocatorState { _unused = 0 }
pub const global_allocator = Allocator {
    impl = &global_allocator_state as &u8,
    vtable = &global_allocator_vtable
}

pub fn or_global(alloc: &Allocator?) &Allocator {
    return alloc.unwrap_or(&global_allocator)
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
    if (end_offset > state.buffer.len) {
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
    if (memory.len == 0) {
        return fixed_alloc(impl, new_size, 1)
    }

    // Check if this is the most recent allocation (can extend in place)
    let mem_start = memory.ptr as usize
    let mem_end = mem_start + memory.len
    let buf_start = state.buffer.ptr as usize
    let current_end = buf_start + state.offset

    if (mem_end == current_end) {
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
    let new_mem = fixed_alloc(impl, new_size, 1)
    if (new_mem.is_none()) {
        return null
    }

    // Copy old data
    let copy_size = if (memory.len < new_size) { memory.len } else { new_size }
    memcpy(new_mem.value.ptr, memory.ptr, copy_size)
    return new_mem
}

fn fixed_free(impl: &u8, memory: u8[]) {
    // FixedBufferAllocator does not support individual frees.
    // Memory is reclaimed by resetting the allocator.
}

// VTable instance for FixedBufferAllocator
const fixed_buffer_allocator_vtable = AllocatorVTable {
    alloc = fixed_alloc,
    realloc = fixed_realloc,
    free = fixed_free
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

pub type ArenaAllocatorState = struct {
    backing: &Allocator,
    page_size: usize,
    first_page: &ArenaPage?,
    current_page: &ArenaPage?
}

pub const DEFAULT_ARENA_PAGE_SIZE: usize = 4096

fn arena_new_page(state: &ArenaAllocatorState, min_size: usize) &ArenaPage? {
    const header_size = size_of(ArenaPage)
    const needed = min_size + header_size
    const total = align_up(needed, state.page_size)

    const raw = state.backing.alloc(total, 8)
    if (raw.is_none()) {
        return null
    }

    const page = raw.value.ptr as &ArenaPage
    page.next = null
    page.size = total - header_size
    page.offset = 0

    // Link into chain
    if (state.current_page.is_some()) {
        state.current_page.value.next = page
    }
    if (state.first_page.is_none()) {
        state.first_page = page
    }
    state.current_page = page

    return page
}

fn arena_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    let state = impl as &ArenaAllocatorState
    const header_size = size_of(ArenaPage)

    // Try current page first
    if (state.current_page.is_some()) {
        let page = state.current_page.value
        let aligned_offset = align_up(page.offset, alignment)

        if (aligned_offset + size <= page.size) {
            // Compute pointer: page base + header + aligned offset
            let base = page as &u8
            let ptr = (base as usize + header_size + aligned_offset) as &u8
            page.offset = aligned_offset + size
            return slice_from_raw_parts(ptr, size)
        }
    }

    // Current page doesn't fit — allocate a new page
    let new_page = arena_new_page(state, size)
    if (new_page.is_none()) {
        return null
    }

    let page = new_page.value
    let aligned_offset = align_up(0, alignment)
    let base = page as &u8
    let ptr = (base as usize + header_size + aligned_offset) as &u8
    page.offset = aligned_offset + size
    return slice_from_raw_parts(ptr, size)
}

fn arena_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    // Allocate new, copy old data
    let new_mem = arena_alloc(impl, new_size, 1)
    if (new_mem.is_none()) {
        return null
    }

    let copy_size = if (memory.len < new_size) { memory.len } else { new_size }
    if (copy_size > 0) {
        memcpy(new_mem.value.ptr, memory.ptr, copy_size)
    }
    return new_mem
}

fn arena_free(impl: &u8, memory: u8[]) {
    // Arena does not support individual frees — no-op.
}

const arena_allocator_vtable = AllocatorVTable {
    alloc = arena_alloc,
    realloc = arena_realloc,
    free = arena_free
}

// Create an arena allocator backed by the given allocator.
pub fn arena_allocator(backing: &Allocator, page_size: usize = 4096) ArenaAllocatorState {
    return .{
        backing = backing,
        page_size = page_size,
        first_page = null,
        current_page = null
    }
}

pub fn allocator(state: &ArenaAllocatorState) Allocator {
    return Allocator {
        impl = state as &u8,
        vtable = &arena_allocator_vtable
    }
}

// Reset all pages to offset 0 — keeps pages allocated for reuse.
pub fn reset(state: &ArenaAllocatorState) {
    let page = state.first_page
    loop {
        if (page.is_none()) { break }
        page.value.offset = 0
        page = page.value.next
    }
    state.current_page = state.first_page
}

// Free all pages through the backing allocator.
pub fn deinit(state: &ArenaAllocatorState) {
    const header_size = size_of(ArenaPage)
    let page = state.first_page
    loop {
        if (page.is_none()) { break }
        let next = page.value.next
        let total = page.value.size + header_size
        let raw = slice_from_raw_parts(page.value as &u8, total)
        state.backing.free(raw)
        page = next
    }
    state.first_page = null
    state.current_page = null
}
