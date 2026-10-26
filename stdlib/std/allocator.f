// Generic allocator abstraction with vtable-based polymorphism.

import core.panic
import core.rtti

import std.mem
import std.option
// For the colocated test blocks' assertions only - no shipped code here depends on std.test.
import std.test

// The default allocator. Collections and other allocating structures in the standard library use it
// when no allocator is passed explicitly: `list(8)` is `list(8, context.allocator)`. A collection
// captures the allocator when it is created and keeps it for its whole life, so a later rebind
// never moves memory it already owns.
//
// It starts as the global allocator, the C heap (`malloc` / `free`). Like every context field it is
// dynamically scoped: a rebind holds for the block and everything called from it, and the previous
// allocator is back when the block ends.
//
//     let names = list(16, &arena) // this collection only
//
//     context(allocator = &arena) {
//         let names = list(16) // everything allocated in the block
//     }
pub context allocator: &Allocator = &global_allocator

// The temporary allocator, for short-lived allocations with a known lifetime: everything allocated
// between a fixed start and end - a request, a frame, a test - can be reclaimed all at once at the
// end. It is usually rebound to an arena that is reset when that work is done:
//
//     const frame = arena.allocator()
//     context(temp_allocator = &frame) {
//         render(scene)
//     }
//     arena.reset()
//
// It starts as the global allocator, the same default as `allocator`.
pub context temp_allocator: &Allocator = &global_allocator

// =============================================================================
// Allocator - interface for memory management
// =============================================================================

// Function type definitions for the allocator vtable. The alignment `malloc`, `realloc` and `free`
// guarantee: enough for any type with fundamental alignment, 16 bytes on every target FLang builds
// for. An allocator built on them declines a request above this rather than returning memory that
// does not meet it. The bump allocators have no such ceiling - they align their own cursor - so the
// limit is the global allocator's, not the interface's.
pub const MAX_ALIGN: usize = 16

// An allocator hands out a `Memory` and takes it back (RFC-043). Only `alloc` is told an alignment.
// `realloc` resizes the block in place of `memory`: true with `memory` now the resized block,
// wherever it lives, keeping its alignment up to `MAX_ALIGN`; false with it untouched. An allocator
// that serves alignments above `MAX_ALIGN` and must release them differently records the alignment
// itself, beside the block.
pub type AllocatorVTable = struct {
    alloc: fn(&u8, size: usize, alignment: usize) Memory?
    realloc: fn(&u8, memory: &Memory, new_size: usize) bool
    dealloc: fn(&u8, move Memory) void
}

// Type-erased allocator interface.
// impl: pointer to allocator-specific state (cast to &u8 for type erasure) vtable: pointer to
// function table
pub type Allocator = struct {
    impl: &u8
    vtable: &AllocatorVTable
}

// Maps a null `&Allocator` to the current context's allocator (spec §4.1), so a zero-initialised
// holder of one allocates and frees through whichever is current at each call.
fn resolved(allocator: &Allocator) &Allocator {
    return if allocator == 0usize as &Allocator { context.allocator } else { allocator }
}

// A block of `size` bytes aligned to `alignment`, or null when the allocator cannot serve it.
pub fn alloc(allocator: &Allocator, size: usize, alignment: usize) Memory? {
    const a = resolved(allocator)
    return a.vtable.alloc(a.impl, size, alignment)
}

// Resize `memory` to `new_size` bytes. True with `memory` now the resized block, which may have
// moved; false with it untouched. The zero block was never allocated, so it is never resized:
// allocate instead.
pub fn realloc(allocator: &Allocator, memory: &Memory, new_size: usize) bool {
    if !memory.is_allocated() {
        return false
    }
    const a = resolved(allocator)
    return a.vtable.realloc(a.impl, memory, new_size)
}

// Give `memory` back to the allocator that handed it out. A region allocator reclaims it later, all
// at once. The zero block was never allocated, so no allocator sees it.
pub fn dealloc(allocator: &Allocator, memory: move Memory) {
    if !memory.is_allocated() {
        leak(memory)
        return
    }
    const a = resolved(allocator)
    a.vtable.dealloc(a.impl, memory)
}

// A raw slot for one `T`. The block is not owned from here: release it with `free`.
pub fn new(allocator: &Allocator, ty: Type($T)) &T {
    const block = allocator.alloc(ty.size, ty.align)
    if block.is_none() {
        panic("Unable to allocate")
    }
    const m = block.unwrap()
    const slot = m.ptr as &T
    leak(m)
    return slot
}

// Allocate a slot for `T` and move `value` into it. Returns a reference to the heap-allocated
// value, which owns it from here.
#inline pub fn box(allocator: &Allocator, value: move $T) &T {
    const ptr = allocator.new(Type(T))
    ptr.* = move value
    return ptr
}

// Release a slot `new` or `box` handed out.
pub fn free(allocator: &Allocator, value: &$T) {
    allocator.dealloc(from_raw(value as &u8, size_of(T)))
}

// Release raw storage for `items.len` elements of `T` that was allocated whole.
pub fn free(allocator: &Allocator, items: $T[]) {
    allocator.dealloc(from_raw(items.ptr as &u8, items.len * size_of(T)))
}

// =============================================================================
// GlobalAllocator - wraps malloc/free from std.mem
// =============================================================================

// GlobalAllocator has no state; we use a dummy struct for the impl pointer.
pub type GlobalAllocatorState = struct {
    _unused: u8
}

// `malloc` takes no alignment and meets `MAX_ALIGN`, which covers every alignment the language can
// currently ask for. A request above it is declined rather than silently under-served; satisfying
// one means `aligned_alloc` / `_aligned_malloc`, and a matching release path.
fn global_alloc(impl: &u8, size: usize, alignment: usize) Memory? {
    if alignment > MAX_ALIGN {
        return null
    }
    return Some(from_raw(malloc(size)?, size))
}

fn global_realloc(impl: &u8, memory: &Memory, new_size: usize) bool {
    const grown = realloc(Some(memory.ptr), new_size)
    if grown.is_none() {
        return false
    }
    const old = replace(memory, from_raw(grown.unwrap(), new_size))
    leak(old)
    return true
}

// The block leaves the language here: C owns it again.
fn global_dealloc(impl: &u8, memory: move Memory) {
    if !memory.is_allocated() {
        leak(memory)
        return
    }
    const ptr = memory.ptr
    leak(memory)
    free(Some(ptr))
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
// wants "the default" reads `context.allocator`, which honours a rebind, so a decorator wrapping
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

fn counting_alloc(impl: &u8, size: usize, alignment: usize) Memory? {
    let state = impl as &CountingAllocator
    const got = state.backing.alloc(size, alignment)
    if got.is_some() {
        state.allocs = state.allocs + 1
        counting_note_growth(state, size)
    }
    return got
}

fn counting_realloc(impl: &u8, memory: &Memory, new_size: usize) bool {
    let state = impl as &CountingAllocator
    const old_size = memory.len
    if !state.backing.realloc(memory, new_size) {
        return false
    }
    state.reallocs = state.reallocs + 1
    if new_size >= old_size {
        counting_note_growth(state, new_size - old_size)
        return true
    }
    state.live_bytes = state.live_bytes - (old_size - new_size)
    return true
}

fn counting_dealloc(impl: &u8, memory: move Memory) {
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
    return Allocator { impl = state as &u8, vtable = &counting_allocator_vtable }
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

test "a null allocator resolves to the current context's" {
    let c = counting_allocator(context.allocator)
    let a = c.allocator()
    const none = 0usize as &Allocator
    context(allocator = &a) {
        const block = none.alloc(64, 8).unwrap()
        assert_eq(c.allocs, 1 as usize, "the rebound allocator served it")
        none.dealloc(block)
    }
    const outside = none.alloc(8, 8).unwrap()
    none.dealloc(outside)
    assert_eq(c.allocs, 1 as usize, "outside the rebind the default serves it")
}

test "a counting decorator tracks live bytes back to zero" {
    let c = counting_allocator(context.allocator)
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
    let c = counting_allocator(context.allocator)
    let backing = c.allocator()
    let arena = arena_allocator(&backing, 4096)
    let a = arena.allocator()

    const x = a.alloc(64, 8).unwrap()
    assert_true(c.live_bytes > 0, "the arena took a page from the backing")
    const with_page = c.live_bytes

    // A second small allocation fits the same page: the backing sees nothing.
    const y = a.alloc(64, 8).unwrap()
    assert_eq(c.live_bytes, with_page, "the arena served it without another page")

    a.dealloc(x)
    a.dealloc(y)
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

// Align a value up to the given alignment, which must be a power of 2.
fn align_up(value: usize, alignment: usize) usize {
    let mask = alignment - 1
    return (value + mask) & ~mask
}

// The bytes between `ptr` and the next address aligned to `alignment`, a power of 2. A bump cursor
// aligns the address it hands out, not its offset into a buffer that may itself sit off the
// alignment.
#allow(W2004)
fn padding_for(ptr: &u8, alignment: usize) usize {
    const addr = ptr as usize
    return align_up(addr, alignment) - addr
}

// The alignment, up to `MAX_ALIGN`, that `memory`'s address meets: at least the one it was
// allocated with, which a block that moves has to keep.
#allow(W2004)
fn block_align(memory: &Memory) usize {
    const addr = memory.ptr as usize
    let a = MAX_ALIGN
    while addr % a != 0 {
        a = a / 2
    }
    return a
}

// Copies `memory`'s bytes into `fresh`, a block of the same region, and puts `fresh` in its place.
// Returns the old block, which the region reclaims with the rest.
fn region_move(memory: &Memory, fresh: move Memory) Memory {
    const count = if memory.len < fresh.len { memory.len } else { fresh.len }
    if count > 0 {
        const from: u8[] = memory.as_slice()
        const into: u8[] = fresh.as_slice()
        copy_to(from[0..count], into)
    }
    return replace(memory, fresh)
}

fn fixed_alloc(impl: &u8, size: usize, alignment: usize) Memory? {
    let state = impl as &FixedBufferAllocatorState

    // Align current offset
    let aligned_offset = state.offset + padding_for(state.buffer.ptr + state.offset, alignment)

    // Check if we have enough space
    let end_offset = aligned_offset + size
    if end_offset > state.buffer.len {
        return null
    }

    // Bump the offset
    state.offset = end_offset
    return Some(from_raw(state.buffer.ptr + aligned_offset, size))
}

fn fixed_realloc(impl: &u8, memory: &Memory, new_size: usize) bool {
    let state = impl as &FixedBufferAllocatorState

    // The most recent allocation, the one whose end meets the bump cursor, extends in place.
    const last = memory.len > 0 and memory.ptr + memory.len == state.buffer.ptr + state.offset
    if last {
        const start = state.offset - memory.len
        if start + new_size <= state.buffer.len {
            state.offset = start + new_size
            leak(replace(memory, from_raw(memory.ptr, new_size)))
            return true
        }
    }

    // Anything else moves; the old block stays in the buffer until a reset.
    const fresh = fixed_alloc(impl, new_size, block_align(memory)) ?? return false
    leak(region_move(memory, fresh))
    return true
}

// The buffer is reclaimed only by a reset, so an individual block owns nothing to give back.
fn fixed_dealloc(impl: &u8, memory: move Memory) {
    leak(memory)
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
    return .{ buffer = buffer, offset = 0 }
}

pub fn allocator(state: &FixedBufferAllocatorState) Allocator {
    return Allocator { impl = state as &u8, vtable = &fixed_buffer_allocator_vtable }
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

// The header at the start of each page: [ArenaPage header | usable bytes...]. A page owns the block
// of the page after it, so the chain is one line of ownership down from the arena.
type ArenaPage = struct {
    next: Memory
    size: usize
    offset: usize
}

// Pages grow geometrically: `page_size` is the first page's size and each page after it doubles, up
// to `ARENA_MAX_PAGE_SIZE`. An arena that allocates once costs one small page; a long-lived one
// stops paying end-of-page slack after a handful of pages.
pub type ArenaAllocator = struct {
    backing: &Allocator
    page_size: usize
    // Size of the next page to allocate; doubles per page, capped.
    next_size: usize
    // The first page's block; each page's header holds the next one's. The arena owns the pages,
    // not the allocations inside them: those are plain references, valid until the arena is reset
    // or released.
    first: Memory
    // The page the bump cursor is in, owning nothing.
    current_page: &ArenaPage?
}

pub const ARENA_MAX_PAGE_SIZE: usize = 131072

// A page holds an `ArenaPage` header followed by whatever the bump cursor aligns for itself, so the
// page only has to satisfy the header. It is what the backing allocator is told on the way in.
pub const ARENA_PAGE_ALIGN: usize = 8

pub const DEFAULT_ARENA_PAGE_SIZE: usize = 4096

// The page a block of the chain holds, or null past its end.
fn page_of(block: &Memory) &ArenaPage? {
    if !block.is_allocated() {
        return null
    }
    return Some(block.ptr as &ArenaPage)
}

// The usable bytes of `page`, after its header.
fn page_data(page: &ArenaPage) &u8 {
    return (page as &u8) + size_of(ArenaPage)
}

// Appends a page with room for `min_size` bytes after the last one and makes it current.
fn arena_new_page(state: &ArenaAllocator, min_size: usize) &ArenaPage? {
    const header_size = size_of(ArenaPage)
    const total = align_up(min_size + header_size, state.next_size)
    if state.next_size < ARENA_MAX_PAGE_SIZE {
        state.next_size = state.next_size * 2
    }
    let block = state.backing.alloc(total, ARENA_PAGE_ALIGN) ?? return null
    const page = block.ptr as &ArenaPage
    page.* = ArenaPage { next = unallocated(), size = total - header_size, offset = 0 }

    let tail = state.current_page ?? page_of(&state.first)
    if tail.is_none() {
        state.first = move block
    } else {
        let last = tail.unwrap()
        while page_of(&last.next).is_some() {
            last = page_of(&last.next).unwrap()
        }
        last.next = move block
    }
    state.current_page = Some(page)
    return Some(page)
}

// Bumps `size` bytes aligned to `alignment` out of `page`; null when they do not fit.
fn page_bump(page: &ArenaPage, size: usize, alignment: usize) Memory? {
    const at = page.offset + padding_for(page_data(page) + page.offset, alignment)
    if at + size > page.size {
        return null
    }
    page.offset = at + size
    return Some(from_raw(page_data(page) + at, size))
}

// Serves from the current page, then from the pages a reset kept after it, then from a new page.
fn arena_alloc(impl: &u8, size: usize, alignment: usize) Memory? {
    let state = impl as &ArenaAllocator
    let page = state.current_page
    while page.is_some() {
        const p = page.unwrap()
        page_bump(p, size, alignment) match {
            Some(block) => {
                state.current_page = page
                return Some(move block)
            }
            None => {}
        }
        page = page_of(&p.next)
    }
    const fresh = arena_new_page(state, size + alignment) ?? return null
    return page_bump(fresh, size, alignment)
}

fn arena_realloc(impl: &u8, memory: &Memory, new_size: usize) bool {
    let state = impl as &ArenaAllocator

    // The most recent allocation, the one whose end meets the bump cursor, resizes in place: the
    // bytes after it are still unclaimed.
    if state.current_page.is_some() {
        const page = state.current_page.unwrap()
        if memory.ptr + memory.len == page_data(page) + page.offset {
            const start = page.offset - memory.len
            if start + new_size <= page.size {
                page.offset = start + new_size
                leak(replace(memory, from_raw(memory.ptr, new_size)))
                return true
            }
        }
    }

    // Anything else moves, onto the alignment the block was allocated with; the old block stays in
    // its page until a reset.
    const fresh = arena_alloc(impl, new_size, block_align(memory)) ?? return false
    leak(region_move(memory, fresh))
    return true
}

// An arena frees everything at once: an individual block goes back to the page that holds it.
fn arena_dealloc(impl: &u8, memory: move Memory) {
    leak(memory)
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
        next_size = page_size,
        first = unallocated(),
        current_page = null,
    }
}

// Gives every page back to the backing allocator, consuming the arena: each page's block moves into
// `dealloc` once the next one has been taken out of its header.
pub fn deinit(self: move ArenaAllocator) {
    let block = move self.first
    while block.is_allocated() {
        const next = replace(&(block.ptr as &ArenaPage).next, unallocated())
        self.backing.dealloc(block)
        block = move next
    }
    self.backing.dealloc(block)
}

// Bytes held across every page, headers included: what the arena took from its backing allocator,
// not what callers asked for.
pub fn capacity_bytes(state: &ArenaAllocator) usize {
    let total: usize = 0
    let page = page_of(&state.first)
    while page.is_some() {
        const p = page.unwrap()
        total = total + p.size + size_of(ArenaPage)
        page = page_of(&p.next)
    }
    return total
}

// Bytes handed out, headers and end-of-page slack excluded.
pub fn used_bytes(state: &ArenaAllocator) usize {
    let total: usize = 0
    let page = page_of(&state.first)
    while page.is_some() {
        const p = page.unwrap()
        total = total + p.offset
        page = page_of(&p.next)
    }
    return total
}

pub fn page_count(state: &ArenaAllocator) usize {
    let n: usize = 0
    let page = page_of(&state.first)
    while page.is_some() {
        n = n + 1
        page = page_of(&page.unwrap().next)
    }
    return n
}

// Empties every page and keeps them all for reuse, in order.
pub fn reset(state: &ArenaAllocator) {
    state.next_size = state.page_size
    let page = page_of(&state.first)
    while page.is_some() {
        const p = page.unwrap()
        p.offset = 0
        if state.next_size < ARENA_MAX_PAGE_SIZE {
            state.next_size = state.next_size * 2
        }
        page = page_of(&p.next)
    }
    state.current_page = page_of(&state.first)
}

pub fn allocator(state: &ArenaAllocator) Allocator {
    return Allocator { impl = state as &u8, vtable = &arena_allocator_vtable }
}

test "a null allocator reference is the global allocator" {
    let none: &Allocator = 0usize as &Allocator
    const buf = none.alloc(16, 8)
    assert_true(buf.is_some(), "allocates through the global")
    none.dealloc(buf.unwrap())
}

test "an arena reuses the pages a reset kept, and frees them all" {
    let c = counting_allocator(context.allocator)
    let backing = c.allocator()
    let arena = arena_allocator(&backing, 64)
    let a = arena.allocator()
    for i in 0..3usize {
        a.dealloc(a.alloc(200, 8).unwrap())
    }
    const pages = arena.page_count()
    arena.reset()
    for i in 0..3usize {
        a.dealloc(a.alloc(200, 8).unwrap())
    }
    assert_eq(arena.page_count(), pages, "the second round fits the kept pages")
    arena.deinit()
    assert_eq(c.live_bytes, 0 as usize, "every page went back, the reused ones too")
}

#allow(W2004)
test "bump allocators align the address they hand out" {
    let arena = arena_allocator(context.allocator)
    let a = arena.allocator()
    const one = a.alloc(1, 1).unwrap()
    const wide = a.alloc(16, 16).unwrap()
    assert_eq((wide.ptr as usize) % 16, 0 as usize, "a 16-byte request lands on 16")
    a.dealloc(one)
    a.dealloc(wide)
    arena.deinit()

    let buf = [0u8; 64]
    const off: u8[] = buf
    let fba = fixed_buffer_allocator(off[1..64])
    let f = fba.allocator()
    const m = f.alloc(8, 8).unwrap()
    assert_eq((m.ptr as usize) % 8, 0 as usize, "an unaligned buffer still serves aligned blocks")
    f.dealloc(m)
}
