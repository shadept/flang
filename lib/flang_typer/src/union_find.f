// Generic union-find with checkpoint/rollback. The inference engine uses it over `VarId`; written
// generically so the disjoint-set logic is testable on its own.
//
// `find(k)` returns the representative of `k`'s partition, auto- inserting `k` (singleton) on first
// sight; path halving on each hop keeps amortised lookups near constant.
//
// `merge(a, b)` is **first-argument-wins** - `a`'s representative becomes the rep of the unioned
// partition. The inference engine relies on this so concrete types stay as reps and unbound
// variables become children when a `Var` is unified with a concrete `Ty`.
//
// `push_checkpoint` / `rollback` / `commit` give callers a speculative region: every `merge`
// between push and rollback is undone; commit keeps them. Used by `try_unify` for
// overload-resolution scoring and by coercion rules that explore alternatives before committing.

import std.allocator
import std.collections.dict
import std.collections.journal
import std.option

// One partition's bookkeeping: the parent pointer (self-referential at the root) plus the size of
// the partition rooted here. Size doesn't drive balancing - see `merge` below - but it's exposed
// for debug / statistics consumers.
pub type UnionFindNode = struct(K) {
    parent: K
    size: usize
}

// One entry in the undo log: enough to restore a single dict mutation. `was_new` covers the case
// where the key did not exist before the mutation, so rollback must remove it rather than restore a
// prior value.
pub type UnionFindUndo = struct(K) {
    key: K
    old_parent: K
    old_size: usize
    was_new: bool
}

// Disjoint-set forest over keys of type `K`, with speculative regions: `push_checkpoint` opens one,
// and every `find` and `merge` inside it is either kept by `commit` or undone by `rollback`. One
// allocator serves the node table and the undo journal.
pub type UnionFind = struct(K) {
    nodes: UnmanagedDict(K, UnionFindNode(K))
    // The undo log of the open speculative regions: `push_checkpoint` opens one, `rollback` replays
    // it in reverse, `commit` folds it into the enclosing region.
    undo: Journal(UnionFindUndo(K))
    // The one allocator the nodes, the stack and every frame allocate through.
    allocator: &Allocator
}

// Creates an empty forest. Nothing allocates until the first `find`.
//
// - `allocator`: kept for the forest's whole life. Null is the global allocator.
pub fn union_find(allocator: &Allocator? = null) UnionFind($K) {
    let out: UnionFind(K)
    out.allocator = allocator.or_global()
    let undo: Journal(UnionFindUndo(K)) = journal(out.allocator)
    out.undo = move undo
    return move out
}

// Frees the node table and the undo journal, open regions included. Idempotent.
pub fn deinit(self: &UnionFind($K)) {
    self.nodes.deinit(self.allocator)
    self.undo.deinit()
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &UnionFind($K), allocator: &Allocator) {
    self.deinit()
}

// Find the representative of `k`'s partition, auto-inserting `k` as a singleton on first sight.
// Walks parent pointers to the root and applies path halving (`node.parent = parent.parent` at each
// hop).
pub fn find(self: &UnionFind($K), k: K) K {
    let existing = self.nodes.get(k)
    if existing.is_none() {
        record_undo(self, k, k, 1, true)
        self.nodes.set(k, .{ parent = k, size = 1 }, self.allocator)
        return k
    }

    let cur = k
    loop {
        let node = self.nodes.get(cur).unwrap()
        if node.parent == cur {
            return cur
        }
        // Path halving - repoint `cur` at its grandparent.
        let parent_node = self.nodes.get(node.parent).unwrap()
        if parent_node.parent != node.parent {
            record_undo(self, cur, node.parent, node.size, false)
            self.nodes.set(cur, .{ parent = parent_node.parent, size = node.size }, self.allocator)
        }
        cur = node.parent
    }
}

// Merge the partitions of `a` and `b`. `a`'s representative becomes the root of the merged
// partition (first-argument-wins). Idempotent when `a` and `b` are already in the same partition.
pub fn merge(self: &UnionFind($K), a: K, b: K) {
    let root_a = self.find(a)
    let root_b = self.find(b)
    if root_a == root_b {
        return
    }

    let node_a = self.nodes.get(root_a).unwrap()
    let node_b = self.nodes.get(root_b).unwrap()

    record_undo(self, root_b, node_b.parent, node_b.size, false)
    record_undo(self, root_a, node_a.parent, node_a.size, false)

    self.nodes.set(root_b, .{ parent = root_a, size = node_b.size }, self.allocator)
    self.nodes.set(root_a, .{ parent = root_a, size = node_a.size + node_b.size }, self.allocator)
}

// Opens a speculative region: every `find` and `merge` until the matching `commit` or `rollback` is
// logged. Regions nest, and each `commit` or `rollback` closes the innermost open one.
pub fn push_checkpoint(self: &UnionFind($K)) {
    self.undo.checkpoint()
}

// Closes the innermost region and keeps its mutations. An enclosing region's `rollback` still
// undoes them. Panics when no region is open.
pub fn commit(self: &UnionFind($K)) {
    self.undo.commit()
}

// Closes the innermost region and undoes its mutations, newest first, restoring the node table to
// exactly what it was when the region opened. Panics when no region is open.
pub fn rollback(self: &UnionFind($K)) {
    self.undo.rollback(fn(entry: UnionFindUndo(K)) {
        if entry.was_new {
            let _removed = self.nodes.remove(entry.key, self.allocator)
        } else {
            self.nodes.set(entry.key, .{
                parent = entry.old_parent,
                size = entry.old_size,
            }, self.allocator)
        }
    })
}

// Record one mutation in the innermost open region. No-op outside a checkpoint, so non-speculative
// callers pay nothing - not even building the entry.
fn record_undo(self: &UnionFind($K), key: K, old_parent: K, old_size: usize, was_new: bool) {
    if !self.undo.is_open() {
        return
    }
    self.undo.record(.{ key = key, old_parent = old_parent, old_size = old_size,
        was_new = was_new })
}
