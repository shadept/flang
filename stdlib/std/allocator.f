// Generic allocator abstraction with vtable-based polymorphism.

import core.panic
import core.rtti

import std.mem
import std.option
// For the colocated test blocks' assertions only - no shipped code here depends on std.test.
import std.test

// The allocator an omitted `&Allocator?` argument resolves to. `set_global_allocator` is the only
// writer; `global()` and `or_global` are the readers. Null means "nobody has installed one", which
// is also the state the global's zeroed storage is in before any initializer runs. That matters:
// constant initializers allocate, they run in module registration order, and one ordered ahead of
// this module would otherwise read an uninitialized pointer out of the slot.
type GlobalSlot = struct {
    current: &Allocator?
}

const global_slot = GlobalSlot { current = null }

// Install `a` as the process-wide default and return the allocator it replaced, so a caller can
// scope the change:
//
//     const prev = set_global_allocator(&mine)
//     defer { let _ = set_global_allocator(prev) }
//
// There is no way to unset: the default is always some allocator, and restoring means holding the
// instance this returned.
//
// ponytail: one process-wide slot, no synchronization. FLang has no threads yet; when it does this
// wants to become thread-local, with the process-wide value as the initial value of each thread's.
pub fn set_global_allocator(a: &Allocator) &Allocator {
    // A `const` binding cannot be assigned through, but a reference to one addresses the global's
    // storage directly, and that storage is writable. Same mechanism the tracking allocators use to
    // keep their state.
    let slot = &global_slot
    const prev = slot.current.unwrap_or(&global_allocator)
    slot.current = Some(a)
    return prev
}

// The allocator currently installed as the default.
pub fn global() &Allocator {
    return global_slot.current.unwrap_or(&global_allocator)
}

pub fn or_global(alloc: &Allocator?) &Allocator {
    return alloc.unwrap_or(global())
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
// impl: pointer to allocator-specific state (cast to &u8 for type erasure) vtable: pointer to
// function table
pub type Allocator = struct {
    impl: &u8
    vtable: &AllocatorVTable
}

// Allocate `size` bytes with given `alignment`.
// Returns pointer to allocated memory or null on failure.
pub fn alloc(allocator: &Allocator, size: usize, alignment: usize) u8[]? {
    return allocator.vtable.alloc(allocator.impl, size, alignment)
}

// Reallocate an existing allocation to a new size. Returns new pointer or null on failure. Some
// allocators may not support realloc and return null.
pub fn realloc(allocator: &Allocator, memory: u8[], new_size: usize) u8[]? {
    return allocator.vtable.realloc(allocator.impl, memory, new_size)
}

// Free memory previously allocated by this allocator. Some allocators (like FixedBufferAllocator)
// may do nothing.
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

// Allocate a slot for `T` and copy `value` into it. Returns a reference to the heap-allocated
// value.
#inline pub fn box(allocator: &Allocator, value: $T) &T {
    const ptr = allocator.new(Type(T))
    ptr.* = value
    return ptr
}

pub fn free(allocator: &Allocator, value: &$T) {
    const slice = slice_from_raw_parts(value as &u8, size_of(T))
    allocator.dealloc(slice)
}

// Free a typed slice. The slice's `len` is taken as the count of T elements to release (use the
// slice's full backing extent - for a `List`/`Dict` buffer that means slicing over `cap`, not
// `len`).
pub fn free(allocator: &Allocator, items: $T[]) {
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
    // malloc typically returns suitably aligned memory for any type. For now we ignore alignment
    // and rely on malloc's default alignment.
    return Some(slice_from_raw_parts(malloc(size)?, size))
}

fn global_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    return Some(slice_from_raw_parts(realloc(Some(memory.ptr), new_size)?, new_size))
}

fn global_dealloc(impl: &u8, memory: u8[]) {
    free(Some(memory.ptr))
}

// VTable instance for GlobalAllocator
const global_allocator_vtable = AllocatorVTable {
    alloc = global_alloc,
    realloc = global_realloc,
    dealloc = global_dealloc,
}

// Singleton state for GlobalAllocator (no actual state needed)
const global_allocator_state = GlobalAllocatorState { _unused = 0 }

// The malloc/free allocator every process starts out defaulting to. Private on purpose: code that
// wants "the default" asks `global()`, which honours whatever is installed, so a decorator wrapping
// the default (a leak tracker, a counting allocator) is not bypassed by a direct reference here.
const global_allocator = Allocator {
    impl = &global_allocator_state as &u8,
    vtable = &global_allocator_vtable,
}

// =============================================================================
// CountingAllocator - a decorator that measures what passes through it
// =============================================================================

// Wraps any allocator, forwards every call to it, and keeps a running total of the bytes currently
// out and the high-water mark they reached.
//
// The bookkeeping is O(1) per call and holds no per-allocation state. The counters say how large a
// pool grew and whether it went back to zero; they name no individual allocation.
//
// `live_bytes` is exact where every free goes back through this same decorator. An arena frees its
// pages through its BACKING allocator, so a decorator wrapping the backing is the one that sees an
// arena's footprint.
pub type CountingAllocator = struct {
    backing: &Allocator
    // Bytes handed out and not yet given back.
    live_bytes: usize
    // The largest `live_bytes` ever reached.
    peak_bytes: usize
    // Bytes handed out over the decorator's whole life, growth included.
    total_bytes: usize
    allocs: usize
    reallocs: usize
    deallocs: usize
}

pub fn counting_allocator(backing: &Allocator) CountingAllocator {
    return .{
        backing = backing,
        live_bytes = 0,
        peak_bytes = 0,
        total_bytes = 0,
        allocs = 0,
        reallocs = 0,
        deallocs = 0,
    }
}

fn counting_note_growth(state: &CountingAllocator, bytes: usize) {
    state.live_bytes = state.live_bytes + bytes
    state.total_bytes = state.total_bytes + bytes
    if state.live_bytes > state.peak_bytes {
        state.peak_bytes = state.live_bytes
    }
}

fn counting_alloc(impl: &u8, size: usize, alignment: usize) u8[]? {
    let state = impl as &CountingAllocator
    const got = state.backing.alloc(size, alignment)
    if got.is_none() {
        return null
    }
    state.allocs = state.allocs + 1
    counting_note_growth(state, size)
    return got
}

fn counting_realloc(impl: &u8, memory: u8[], new_size: usize) u8[]? {
    let state = impl as &CountingAllocator
    const old_size = memory.len
    const got = state.backing.realloc(memory, new_size)
    if got.is_none() {
        return null
    }
    state.reallocs = state.reallocs + 1
    if new_size >= old_size {
        counting_note_growth(state, new_size - old_size)
        return got
    }
    state.live_bytes = state.live_bytes - (old_size - new_size)
    return got
}

fn counting_dealloc(impl: &u8, memory: u8[]) {
    let state = impl as &CountingAllocator
    state.deallocs = state.deallocs + 1
    // A free of memory this decorator never handed out clamps the running total at zero; the alloc
    // and free counts are where it shows.
    if memory.len > state.live_bytes {
        state.live_bytes = 0
    } else {
        state.live_bytes = state.live_bytes - memory.len
    }
    state.backing.dealloc(memory)
}

const counting_allocator_vtable = AllocatorVTable {
    alloc = counting_alloc,
    realloc = counting_realloc,
    dealloc = counting_dealloc,
}

pub fn allocator(state: &CountingAllocator) Allocator {
    return Allocator {
        impl = state as &u8,
        vtable = &counting_allocator_vtable,
    }
}

// Start counting again from here, with whatever is currently live as the new baseline. Measures one
// phase of a long-running program.
pub fn reset_counts(state: &CountingAllocator) {
    state.peak_bytes = state.live_bytes
    state.total_bytes = 0
    state.allocs = 0
    state.reallocs = 0
    state.deallocs = 0
}

#allow (W2004)
test "an installed global allocator is what or_global resolves to" {
    let c = counting_allocator(global())
    let a = c.allocator()

    const prev = set_global_allocator(&a)
    const mine: &Allocator? = null
    const resolved = mine.or_global()
    const _block = resolved.alloc(64, 8).unwrap()
    assert_eq(c.allocs, 1 as usize, "an omitted allocator reached the installed one")
    resolved.dealloc(_block)

    const restored = set_global_allocator(prev)
    assert_true(restored.impl as usize == (&a).impl as usize, "the swap returns what it replaced")
    assert_true(global().impl as usize == prev.impl as usize, "and the previous one is back")
}

test "a counting decorator tracks live bytes back to zero" {
    let c = counting_allocator(global())
    let a = c.allocator()

    const one = a.alloc(100, 8).unwrap()
    const two = a.alloc(40, 8).unwrap()
    assert_eq(c.live_bytes, 140 as usize, "both allocations are out")
    assert_eq(c.peak_bytes, 140 as usize, "the high-water mark saw both")

    a.dealloc(two)
    assert_eq(c.live_bytes, 100 as usize, "a free gives its bytes back")
    assert_eq(c.peak_bytes, 140 as usize, "the high-water mark does not fall")

    a.dealloc(one)
    assert_eq(c.live_bytes, 0 as usize, "nothing is left out")
    assert_eq(c.allocs, 2 as usize, "two allocations")
    assert_eq(c.deallocs, 2 as usize, "two frees")
    assert_eq(c.total_bytes, 140 as usize, "the lifetime total counts growth, not the peak")
}

test "a decorator sees an arena's pages through its backing" {
    // An arena frees its pages through its BACKING allocator, so that is where a decorator has to
    // sit to see the arena's footprint go to zero.
    let c = counting_allocator(global())
    let backing = c.allocator()
    let arena = arena_allocator(&backing, 4096)
    let a = arena.allocator()

    const _x = a.alloc(64, 8).unwrap()
    assert_true(c.live_bytes > 0, "the arena took a page from the backing")
    const with_page = c.live_bytes

    // A second small allocation fits the same page: the backing sees nothing.
    const _y = a.alloc(64, 8).unwrap()
    assert_eq(c.live_bytes, with_page, "the arena served it without another page")

    arena.deinit()
    assert_eq(c.live_bytes, 0 as usize, "deinit hands every page back")
}

// =============================================================================
// FixedBufferAllocator - bump allocator over a provided buffer
// =============================================================================

// State for the fixed buffer allocator.
// Tracks the buffer, its size, and current allocation offset.
pub type FixedBufferAllocatorState = struct {
    buffer: u8[]
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

    return Some(new_memory)
}

#allow (W2004)
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
            return Some(slice_from_raw_parts(memory.ptr, new_size))
        }
    }

    // Cannot extend in place - allocate new and copy
    let new_mem = fixed_alloc(impl, new_size, 1)?

    // Copy old data
    let copy_size = if memory.len < new_size { memory.len } else { new_size }
    memcpy(new_mem.ptr, memory.ptr, copy_size)
    return Some(new_mem)
}

fn fixed_dealloc(impl: &u8, memory: u8[]) {
    // FixedBufferAllocator does not support individual frees. Memory is reclaimed by resetting the
    // allocator.
}

// VTable instance for FixedBufferAllocator
const fixed_buffer_allocator_vtable = AllocatorVTable {
    alloc = fixed_alloc,
    realloc = fixed_realloc,
    dealloc = fixed_dealloc,
}

// Initialize a FixedBufferAllocator from a pre-allocated buffer. This allocator should not outlive
// the provided buffer.
pub fn fixed_buffer_allocator(buffer: u8[]) FixedBufferAllocatorState {
    return .{
        buffer = buffer,
        offset = 0,
    }
}

pub fn allocator(state: &FixedBufferAllocatorState) Allocator {
    return Allocator {
        impl = state as &u8,
        vtable = &fixed_buffer_allocator_vtable,
    }
}

// Reset a FixedBufferAllocator to reuse its buffer from the beginning.
pub fn reset(state: &FixedBufferAllocatorState) {
    state.offset = 0
}

// =============================================================================
// ArenaAllocator - page-based bump allocator with bulk teardown
// =============================================================================
// Arena semantics: bump-allocate within pages, no individual free, bulk teardown via
// reset()/deinit(). Composable with any backing allocator.

// Intrusive linked list header at the start of each page. Page layout in memory: [ArenaPage header
// | usable bytes...]
type ArenaPage = struct {
    next: &ArenaPage?
    size: usize
    offset: usize
}

pub type ArenaAllocator = struct {
    backing: &Allocator
    page_size: usize
    first_page: &ArenaPage?
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
        Some(cp) => { cp.next = Some(page) }
        None => {}
    }
    if state.first_page.is_none() {
        state.first_page = Some(page)
    }
    state.current_page = Some(page)

    return Some(page)
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
            let ptr = base + (header_size + aligned_offset)
            page.offset = aligned_offset + size
            return Some(slice_from_raw_parts(ptr, size))
        }
    }

    // Current page doesn't fit - allocate a new page
    let new_page = arena_new_page(state, size)
    if new_page.is_none() {
        return null
    }

    let page = new_page.unwrap()
    let aligned_offset = align_up(0, alignment)
    let base = page as &u8
    let ptr = base + (header_size + aligned_offset)
    page.offset = aligned_offset + size
    return Some(slice_from_raw_parts(ptr, size))
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
    // Arena does not support individual frees - no-op.
}

const arena_allocator_vtable = AllocatorVTable {
    alloc = arena_alloc,
    realloc = arena_realloc,
    dealloc = arena_dealloc,
}

// Create an arena allocator backed by the given allocator.
pub fn arena_allocator(backing: &Allocator, page_size: usize = 4096) ArenaAllocator {
    return .{
        backing = backing,
        page_size = page_size,
        first_page = null,
        current_page = null,
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

// Reset all pages to offset 0 - keeps pages allocated for reuse.
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
        vtable = &arena_allocator_vtable,
    }
}
