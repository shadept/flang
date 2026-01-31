// Generic allocator abstraction with vtable-based polymorphism.

import core.panic
import core.rtti

import std.mem
import std.option

// =============================================================================
// Allocator - interface for memory management
// =============================================================================

// Function type definitions for the allocator vtable.
pub struct AllocatorVTable {
    alloc: fn(&u8, size: usize, alignment: usize) u8[]?
    realloc: fn(&u8, memory: u8[], new_size: usize) u8[]?
    free: fn(&u8, memory: u8[]) void
}

// Type-erased allocator interface.
// impl: pointer to allocator-specific state (cast to &u8? for type erasure)
// vtable: pointer to function table
pub struct Allocator {
    impl: &u8,
    vtable: &AllocatorVTable
}

// Allocate `size` bytes with given `alignment`.
// Returns pointer to allocated memory or null on failure.
pub fn alloc(allocator: Allocator, size: usize, alignment: usize) u8[]? {
    return allocator.vtable.alloc(allocator.impl, size, alignment)
}

// Reallocate an existing allocation to a new size.
// Returns new pointer or null on failure.
// Some allocators may not support realloc and return null.
pub fn realloc(allocator: Allocator, memory: u8[], new_size: usize) u8[]? {
    return allocator.vtable.realloc(allocator.impl, memory, new_size)
}

// Free memory previously allocated by this allocator.
// Some allocators (like FixedBufferAllocator) may do nothing.
pub fn free(allocator: Allocator, memory: u8[]) {
    allocator.vtable.free(allocator.impl, memory)
}

pub fn new(allocator: Allocator, type: Type($T)) &T {
    const buffer = allocator.alloc(type.size, type.align)
    if (buffer.is_none()) {
        panic("Unable to allocate")
    }
    return buffer.value.ptr as &T
}

pub fn delete(allocator: Allocator, value: &$T) {
    // HACK: fake slice. assuming implementation doesnt care about length
    allocator.free(slice_from_raw_parts(value as &u8, 0))
}

// =============================================================================
// GlobalAllocator - wraps malloc/free from core.mem
// =============================================================================

// GlobalAllocator has no state; we use a dummy struct for the impl pointer.
pub struct GlobalAllocatorState {
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

// =============================================================================
// FixedBufferAllocator - bump allocator over a provided buffer
// =============================================================================

// State for the fixed buffer allocator.
// Tracks the buffer, its size, and current allocation offset.
pub struct FixedBufferAllocatorState {
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
    // FixedBufferAllocator does not support realloc - return null
    return null
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
