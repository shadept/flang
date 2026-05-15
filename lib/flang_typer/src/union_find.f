// Generic union-find with checkpoint/rollback. The inference engine
// uses it over `VarId`; written generically so the disjoint-set logic
// is testable on its own.
//
// `find(k)` returns the representative of `k`'s partition, auto-
// inserting `k` (singleton) on first sight; path halving on each hop
// keeps amortised lookups near constant.
//
// `merge(a, b)` is **first-argument-wins** — `a`'s representative
// becomes the rep of the unioned partition. The inference engine
// relies on this so concrete types stay as reps and unbound variables
// become children when a `Var` is unified with a concrete `Ty`.
//
// `push_checkpoint` / `rollback` / `commit` give callers a speculative
// region: every `merge` between push and rollback is undone; commit
// keeps them. Used by `try_unify` for overload-resolution scoring and
// by coercion rules that explore alternatives before committing.

import std.allocator
import std.dict
import std.list
import std.option
import std.stack

// One partition's bookkeeping: the parent pointer (self-referential at
// the root) plus the size of the partition rooted here. Size doesn't
// drive balancing — see `merge` below — but it's exposed for debug /
// statistics consumers.
pub type UnionFindNode = struct(K) {
    parent: K
    size: usize
}

// One entry in the undo log: enough to restore a single dict mutation.
// `was_new` covers the case where the key did not exist before the
// mutation, so rollback must remove it rather than restore a prior
// value.
pub type UnionFindUndo = struct(K) {
    key: K
    old_parent: K
    old_size: usize
    was_new: bool
}

pub type UnionFind = struct(K) {
    nodes: Dict(K, UnionFindNode(K))
    // Stack of speculative regions. Each frame collects the undo log
    // for mutations performed inside it. `push_checkpoint` adds a
    // frame; `rollback` consumes it; `commit` discards it.
    undo_stack: Stack(List(UnionFindUndo(K)))
    allocator: &Allocator
}

// Construct an empty `UnionFind`. `allocator` resolves to the global
// allocator when null and is stored non-optional on the struct.
pub fn union_find(allocator: &Allocator? = null) UnionFind($K) {
    let alloc = allocator.or_global()
    let nodes: Dict(K, UnionFindNode(K)) = dict(alloc)
    let undo = stack(0, alloc)
    return .{
        nodes = nodes,
        undo_stack = undo,
        allocator = alloc,
    }
}

pub fn deinit(self: &UnionFind($K)) {
    self.nodes.deinit()
    let frames = self.undo_stack.as_slice()
    for i in 0..frames.len {
        let frame = &frames[i]
        frame.deinit()
    }
    self.undo_stack.deinit()
}

// Find the representative of `k`'s partition, auto-inserting `k` as a
// singleton on first sight. Walks parent pointers to the root and
// applies path halving (`node.parent = parent.parent` at each hop).
pub fn find(self: &UnionFind($K), k: K) K {
    let existing = self.nodes.get(k)
    if existing.is_none() {
        record_undo(self, k, k, 1, true)
        self.nodes.set(k, .{ parent = k, size = 1 })
        return k
    }

    let cur = k
    loop {
        let node = self.nodes.get(cur).unwrap()
        if node.parent == cur { return cur }
        // Path halving — repoint `cur` at its grandparent.
        let parent_node = self.nodes.get(node.parent).unwrap()
        if parent_node.parent != node.parent {
            record_undo(self, cur, node.parent, node.size, false)
            self.nodes.set(cur, .{ parent = parent_node.parent, size = node.size })
        }
        cur = node.parent
    }
}

// Merge the partitions of `a` and `b`. `a`'s representative becomes
// the root of the merged partition (first-argument-wins). Idempotent
// when `a` and `b` are already in the same partition.
pub fn merge(self: &UnionFind($K), a: K, b: K) {
    let root_a = self.find(a)
    let root_b = self.find(b)
    if root_a == root_b { return }

    let node_a = self.nodes.get(root_a).unwrap()
    let node_b = self.nodes.get(root_b).unwrap()

    record_undo(self, root_b, node_b.parent, node_b.size, false)
    record_undo(self, root_a, node_a.parent, node_a.size, false)

    self.nodes.set(root_b, .{ parent = root_a, size = node_b.size })
    self.nodes.set(root_a, .{ parent = root_a, size = node_a.size + node_b.size })
}

// Begin a speculative region. Every subsequent `merge` is recorded in
// a fresh undo frame that `rollback` will replay in reverse, or that
// `commit` will discard. Frames stack.
pub fn push_checkpoint(self: &UnionFind($K)) {
    let frame = list(0, self.allocator)
    self.undo_stack.push(frame)
}

// Discard the top frame, keeping every mutation it recorded.
pub fn commit(self: &UnionFind($K)) {
    let frame = self.undo_stack.pop().expect("commit: no open checkpoint")
    frame.deinit()
}

// Undo every mutation in the top frame, in reverse order, then discard
// the frame. The dict is restored byte-for-byte to its pre-checkpoint
// state.
pub fn rollback(self: &UnionFind($K)) {
    let frame = self.undo_stack.pop().expect("rollback: no open checkpoint")
    let i = frame.len
    loop {
        if i == 0 { break }
        i = i - 1
        let entry = &frame[i]
        if entry.was_new {
            self.nodes.remove(entry.key)
        } else {
            self.nodes.set(entry.key, .{
                parent = entry.old_parent,
                size = entry.old_size,
            })
        }
    }
    frame.deinit()
}

// Record one mutation in the top-of-stack undo frame, if there is one.
// No-op outside a checkpoint, so non-speculative callers pay nothing.
fn record_undo(self: &UnionFind($K), key: K, old_parent: K, old_size: usize, was_new: bool) {
    self.undo_stack.peek_ref() match {
        Some(top) => top.push(.{
            key = key,
            old_parent = old_parent,
            old_size = old_size,
            was_new = was_new,
        }),
        None => {},
    }
}
