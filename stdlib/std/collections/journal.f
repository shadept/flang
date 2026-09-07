// An undo log with nested checkpoints, for speculative regions: try a unification, an overload
// candidate, a merge, and either keep every mutation or take them all back in reverse order.
//
// The log is flat. Every open checkpoint's entries sit end to end in one list, and a second list
// holds where each checkpoint's entries start, so:
//
//   - a checkpoint costs one index push, never a block of its own;
//   - `commit` pops the mark and the entries fold into the enclosing checkpoint, so an outer
//     `rollback` still undoes them - nesting is correct by construction;
//   - `rollback` and `commit` truncate and never free, so the two buffers reach their high-water
//     mark once and every later checkpoint reuses them. A long-lived journal allocates a handful
//     of times over the life of a checker.
//
// A journal is a managed composite over the unmanaged building blocks: it stores its allocator once
// and has no unmanaged twin.

import std.allocator
import std.collections.list
import std.option
import std.test

// An undo log of `T` entries with nested checkpoints.
//
// A checkpoint opens a speculative region; `record` appends one entry per mutation made inside it;
// `rollback` hands the region's entries back newest first for the caller to undo, and `commit`
// keeps them. Regions nest, and a committed inner region's entries belong to the region around it.
// The log is one contiguous buffer plus one of marks, both kept at their high-water mark: after the
// first few regions a checkpoint allocates nothing.
pub type Journal = struct(T) {
    // Every open checkpoint's entries, oldest first.
    entries: UnmanagedList(T)
    // Where each open checkpoint's entries start, outermost first.
    marks: UnmanagedList(usize)
    allocator: &Allocator
}

// Creates an empty journal. Nothing allocates until the first checkpoint.
//
// - `allocator`: kept for the journal's whole life; both buffers grow and free through it. Null is
//   the global allocator.
pub fn journal(allocator: &Allocator? = null) Journal($T) {
    let out: Journal(T)
    out.allocator = allocator.or_global()
    return out
}

// Creates an empty journal that allocates through `allocator` for its whole life.
pub fn journal(allocator: &Allocator) Journal($T) {
    return journal(Some(allocator))
}

// Opens a checkpoint: every `record` until the matching `commit` or `rollback` belongs to it.
// Checkpoints nest, and each `commit` or `rollback` closes the innermost open one. Panics when the
// mark buffer cannot grow.
pub fn checkpoint(self: &Journal($T)) {
    self.marks.push(self.entries.len, self.allocator)
}

// Returns whether any checkpoint is open. `record` does nothing outside one, so a caller whose
// entry is expensive to build checks this first and skips building it.
pub fn is_open(self: &Journal($T)) bool {
    return self.marks.len > 0
}

// Returns the number of open checkpoints.
pub fn depth(self: &Journal($T)) usize {
    return self.marks.len
}

// Logs one mutation against the innermost open checkpoint.
//
// With no checkpoint open the entry is dropped and nothing is stored: code outside a speculative
// region pays nothing for recording. Panics when the log cannot grow.
//
// - `entry`: whatever `rollback`'s callback needs to undo the mutation, typically the key and the
//   value it replaced. The journal owns it from here and deinits it with the log.
pub fn record(self: &Journal($T), entry: T) {
    if self.marks.len == 0 {
        return
    }
    self.entries.push(entry, self.allocator)
}

// Closes the innermost checkpoint and keeps its mutations.
//
// Its entries now belong to the enclosing checkpoint, so an enclosing `rollback` still undoes them.
// Closing the outermost checkpoint empties the log: nothing can undo those entries any more. Panics
// when no checkpoint is open.
pub fn commit(self: &Journal($T)) {
    const _mark = self.marks.pop().expect("journal: commit with no open checkpoint")
    if self.marks.len == 0 {
        self.entries.truncate(0)
    }
}

// Closes the innermost checkpoint and hands its entries to `undo`, newest first, then drops them.
//
// - `undo`: `fn(T)`, called once per entry in reverse order of recording, so an entry sees the
//   state every later entry left behind. It must not `record` or open a checkpoint on this journal.
//
// Panics when no checkpoint is open.
pub fn rollback(self: &Journal($T), undo: $F) {
    const mark = self.marks.pop().expect("journal: rollback with no open checkpoint")
    for entry in self.entries[mark..].iter_rev() {
        undo(entry)
    }
    self.entries.truncate(mark)
}

// Drops every checkpoint and entry without undoing anything. The storage is kept for reuse.
pub fn clear(self: &Journal($T)) {
    self.entries.clear()
    self.marks.clear()
}

// Deinits every entry still logged and frees both buffers. Idempotent: a second call is a no-op.
pub fn deinit(self: &Journal($T)) {
    self.entries.deinit(self.allocator)
    self.marks.deinit(self.allocator)
}

// Returns the bytes both buffers occupy: the whole capacity, which is the journal's high-water mark
// once it has settled.
pub fn capacity_bytes(self: &Journal($T)) usize {
    return self.entries.capacity_bytes() + self.marks.capacity_bytes()
}

// =============================================================================
// Tests
// =============================================================================

// A counter whose history the tests journal: each entry is the value before a change.
fn apply_undo(counter: &i32, previous: i32) {
    counter.* = previous
}

test "rollback undoes the innermost checkpoint newest first; commit keeps it" {
    let value = 0i32
    let j: Journal(i32) = journal()
    defer j.deinit()

    j.record(99i32)
    assert_eq(j.entries.len, 0 as usize, "recording outside a checkpoint is a no-op")

    j.checkpoint()
    j.record(value)
    value = 1
    j.record(value)
    value = 2
    let target = &value
    j.rollback(fn(prev) { apply_undo(target, prev) })
    assert_eq(value, 0i32, "both mutations undone, in reverse")
    assert_eq(j.depth(), 0 as usize, "the checkpoint is closed")

    j.checkpoint()
    j.record(value)
    value = 5
    j.commit()
    assert_eq(value, 5i32, "commit keeps the mutation")
    assert_eq(j.entries.len, 0 as usize, "and with no enclosing checkpoint the entries are gone")
}

test "an inner commit folds into the outer checkpoint, which an outer rollback still undoes" {
    let value = 0i32
    let j: Journal(i32) = journal()
    defer j.deinit()
    let target = &value

    j.checkpoint()
    j.record(value)
    value = 1
    j.checkpoint()
    j.record(value)
    value = 2
    j.commit()
    assert_eq(value, 2i32, "the inner region kept its change")
    assert_eq(j.depth(), 1 as usize, "one checkpoint left")
    j.rollback(fn(prev) { apply_undo(target, prev) })
    assert_eq(value, 0i32, "the outer rollback undid the inner region's change too")
}

test "a journal reaches its high-water mark and then stops allocating" {
    let counting = counting_allocator(global())
    const alloc = counting.allocator()
    let j: Journal(i32) = journal(&alloc)
    for round in 0..50i32 {
        j.checkpoint()
        j.checkpoint()
        for i in 0..20i32 {
            j.record(i)
        }
        j.commit()
        j.rollback(fn(prev) {})
    }
    const after_warmup = counting.allocs
    for round in 0..50i32 {
        j.checkpoint()
        for i in 0..20i32 {
            j.record(i)
        }
        j.rollback(fn(prev) {})
    }
    assert_eq(counting.allocs, after_warmup, "no allocation once the buffers have settled")
    j.deinit()
    assert_eq(counting.live_bytes, 0 as usize, "both buffers freed")
}
