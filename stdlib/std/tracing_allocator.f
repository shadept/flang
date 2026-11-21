// TracingAllocator: a decorator that remembers where every live block came from.
//
// Wraps any allocator and records, per live block, its size, the generation it was born in and the
// native stack that asked for it. `mark` opens a new generation; `live_sites` groups the blocks of
// a generation range still live by stack, largest first. Repeating the same work once per
// generation separates a leak from state kept on purpose: what a round keeps is replaced by the
// next round, so a block born in an earlier round and still live at the end was never let go.
//
//     let tracer = tracing_allocator(context.allocator)
//     let traced = tracer.allocator()
//     context(allocator = &traced) { work() }
//     const round = tracer.mark()
//     context(allocator = &traced) { work() }
//     let sites = tracer.live_sites(round, round)
//
// The bookkeeping lives in hash tables grown through the BACKING allocator, never through this
// decorator, so tracing does not trace itself. Each call captures a stack; distinct stacks are
// stored once. Costs a stack walk per allocation and about 40 bytes per live block: a debugging
// tool, not a production allocator.

import core.string

import std.allocator
import std.collections.dict
import std.collections.list
import std.mem
import std.option
import std.sort
import std.string
import std.test

#foreign fn __flang_trace_capture(frames: &usize, max: usize) usize
#foreign fn __flang_trace_symbol(addr: usize, buf: &u8, cap: usize) usize

type TracedBlock = struct {
    size: usize
    generation: u32
    stack: u32
}

pub type TracingAllocator = struct {
    backing: &Allocator
    // Live blocks by `block_key`.
    blocks: UnmanagedDict(usize, TracedBlock)
    // Stack hash -> stack id. An id indexes `starts`; its frames are `frames[starts[id]..]` up to
    // the next stack's start.
    stack_ids: UnmanagedDict(usize, u32)
    frames: UnmanagedList(usize)
    starts: UnmanagedList(usize)
    generation: u32
}

// The live blocks one stack allocated: `stack` names it for `stack_frames`.
pub type AllocSite = struct {
    stack: u32
    blocks: usize
    bytes: usize
}

pub fn tracing_allocator(backing: &Allocator) TracingAllocator {
    return .{
        backing = backing,
        blocks = unmanaged_dict(0, backing),
        stack_ids = unmanaged_dict(0, backing),
        frames = unmanaged_list(0, backing),
        starts = unmanaged_list(0, backing),
        generation = 0,
    }
}

pub fn deinit(self: move TracingAllocator) {
    self.blocks.deinit(self.backing)
    self.stack_ids.deinit(self.backing)
    self.frames.deinit(self.backing)
    self.starts.deinit(self.backing)
}

pub fn allocator(state: &TracingAllocator) Allocator {
    return Allocator { impl = state as &u8, vtable = &tracing_allocator_vtable }
}

// Open a new generation and return its number. Blocks allocated from here on are born in it; the
// first generation, before any mark, is 0.
pub fn mark(self: &TracingAllocator) u32 {
    self.generation = self.generation + 1
    return self.generation
}

// Blocks still live.
pub fn live_blocks(self: &TracingAllocator) usize {
    return self.blocks.len()
}

// The live blocks born in generations `first..=last`, grouped by allocation stack, most bytes
// first.
pub fn live_sites(self: &TracingAllocator, first: u32, last: u32) List(AllocSite) {
    let tally: UnmanagedDict(u32, AllocSite) = unmanaged_dict(0, self.backing)
    for e in self.blocks.iter() {
        const b = e.value
        if b.generation < first or b.generation > last {
            continue
        }
        const seen = tally.get(b.stack) ?? AllocSite { stack = b.stack, blocks = 0, bytes = 0 }
        const site = AllocSite {
            stack = b.stack,
            blocks = seen.blocks + 1,
            bytes = seen.bytes + b.size,
        }
        tally.set(b.stack, site, self.backing)
    }
    let out = list(tally.len())
    for s in tally.values() {
        out.push(s)
    }
    tally.deinit(self.backing)
    sort(out.as_slice(), more_bytes)
    return out
}

// The return addresses of stack `stack`, innermost first, the tracer's own frames included.
pub fn stack_frames(self: &TracingAllocator, stack: u32) usize[] {
    const id = stack as usize
    const lo = self.starts[id]
    const hi = if id + 1 < self.starts.len { self.starts[id + 1] } else { self.frames.len }
    return self.frames[lo..hi]
}

// The symbol at return address `addr`, or the bare address when nothing resolves it.
pub fn frame_name(addr: usize) OwnedString {
    let buf = [0u8; 512]
    const view: u8[] = buf
    const n = __flang_trace_symbol(addr, view.ptr, view.len)
    return from_view(from_c_string(view.ptr, Some(n)))
}

fn more_bytes(a: AllocSite, b: AllocSite) Ord {
    if a.bytes > b.bytes {
        return Ord.Less
    }
    if a.bytes < b.bytes {
        return Ord.Greater
    }
    return Ord.Equal
}

#allow(W2004)
fn tracing_alloc(impl: &u8, size: usize, alignment: usize) Memory? {
    let state = impl as &TracingAllocator
    const got = state.backing.alloc(size, alignment)?
    state.record(block_key(got.ptr as usize), size)
    return Some(move got)
}

// A moved block is born again where it moved: a container that keeps growing shows up at the stack
// that grew it, in the generation it last grew.
#allow(W2004)
fn tracing_realloc(impl: &u8, memory: &Memory, new_size: usize) bool {
    let state = impl as &TracingAllocator
    const old = block_key(memory.ptr as usize)
    if !state.backing.realloc(memory, new_size) {
        return false
    }
    state.blocks.remove(old)
    state.record(block_key(memory.ptr as usize), new_size)
    return true
}

#allow(W2004)
fn tracing_dealloc(impl: &u8, memory: move Memory) {
    let state = impl as &TracingAllocator
    if memory.is_allocated() {
        state.blocks.remove(block_key(memory.ptr as usize))
    }
    state.backing.dealloc(memory)
}

const tracing_allocator_vtable = AllocatorVTable {
    alloc = tracing_alloc,
    realloc = tracing_realloc,
    dealloc = tracing_dealloc,
}

// A block's address inverted, so the table holds no pointer to it: a conservative leak scanner
// (macOS `leaks`, LSan) running on the same process still sees an unreachable block as unreachable.
fn block_key(addr: usize) usize {
    return ~addr
}

fn record(state: &TracingAllocator, key: usize, size: usize) {
    const block = TracedBlock {
        size = size,
        generation = state.generation,
        stack = state.intern_stack(),
    }
    state.blocks.set(key, block, state.backing)
}

// The id of the calling stack, stored on first sight.
//
// ponytail: stacks are told apart by a 64-bit hash alone; compare the frames on a hit if a
// collision ever merges two sites.
fn intern_stack(state: &TracingAllocator) u32 {
    let buf = [0usize; 48]
    const view: usize[] = buf
    const n = __flang_trace_capture(view.ptr, view.len)
    const got = view[0..n]
    const key = frames_hash(got)
    const known = state.stack_ids.get(key)
    if known.is_some() {
        return known.unwrap()
    }
    const id = state.starts.len as u32
    state.starts.push(state.frames.len, state.backing)
    state.frames.push_all(got, state.backing)
    state.stack_ids.set(key, id, state.backing)
    return id
}

// FNV-1a over the frame words.
fn frames_hash(frames: usize[]) usize {
    let h = 14695981039346656037usize
    for f in frames {
        h = (h ^ f) * 1099511628211
    }
    return h
}

test "a tracing decorator groups live blocks by stack, within a generation range" {
    let t = tracing_allocator(context.allocator)
    let a = t.allocator()

    const before = a.alloc(16, 8).unwrap()
    const round = t.mark()
    const one = a.alloc(100, 8).unwrap()
    const two = a.alloc(40, 8).unwrap()

    let sites = t.live_sites(round, round)
    assert_eq(sites.len, 2 as usize, "two call sites in the marked round")
    assert_eq(sites[0].bytes, 100 as usize, "the larger site first")
    assert_eq(sites[1].bytes, 40 as usize, "then the smaller")
    assert_true(t.stack_frames(sites[0].stack).len > 0, "the site kept its stack")
    sites.deinit()

    let all = t.live_sites(0, round)
    assert_eq(all.len, 3 as usize, "the unmarked block counts from generation 0")
    all.deinit()

    a.dealloc(one)
    let left = t.live_sites(round, round)
    assert_eq(left.len, 1 as usize, "a freed block leaves its site")
    left.deinit()

    a.dealloc(two)
    a.dealloc(before)
    assert_eq(t.live_blocks(), 0 as usize, "nothing is left out")
    t.deinit()
}

test "a moved block is born again in the generation that moved it" {
    let t = tracing_allocator(context.allocator)
    let a = t.allocator()

    let m = a.alloc(8, 8).unwrap()
    const round = t.mark()
    assert_true(a.realloc(&m, 4096), "the block grows")
    let sites = t.live_sites(round, round)
    assert_eq(sites.len, 1 as usize, "the grown block belongs to the new round")
    assert_eq(sites[0].bytes, 4096 as usize, "at its new size")
    sites.deinit()
    assert_eq(t.live_blocks(), 1 as usize, "one block, not two")

    a.dealloc(m)
    t.deinit()
}

test "a frame resolves to a name" {
    let t = tracing_allocator(context.allocator)
    let a = t.allocator()
    const m = a.alloc(8, 8).unwrap()
    let sites = t.live_sites(0, 0)
    const frames = t.stack_frames(sites[0].stack)
    let name = frame_name(frames[0])
    assert_true(name.view().len > 0, "every frame prints as something")
    name.deinit()
    sites.deinit()
    a.dealloc(m)
    t.deinit()
}
