// Demand order - the sequence the checker visits a module set in.
//
// The order guarantees two things. A module's dependencies are visited before it, so its imports
// are registered by the time it is checked. And one module set always yields one order, whatever
// order the modules were discovered in: every id the checker hands out (nominal, function,
// specialization) is assigned in visit order, and those ids reach the emitted output.
//
// The module graph is not a DAG. Modules within one library may import each other in a cycle
// (docs/spec.md section 6 makes the acyclic rule a library-level one), and the standard library
// contains such cycles. The order is therefore the topological sort of the CONDENSATION: the DAG
// whose nodes are the graph's strongly-connected components. A component is visited only once every
// component it depends on has been. Members of one component have no dependency order between them
// and go in FQN order; roots are entered in FQN order too. A module in no cycle is a singleton
// component, so an acyclic graph gets a plain topological order.
//
//     a -> b -> c        a -> [d <-> e]
//     visit: c, b, a     visit: d, e, a      (d before e by name)
//
// Tarjan's algorithm supplies that order directly: it emits a component only after every component
// reachable from it, which with edges pointing dependent -> dependency is dependencies-first. The
// condensation is never materialised.
//
// Cycles are ordinary input. Reporting them is a caller's job, over the components it can recover
// from the result.

import std.allocator
import std.collections.list
import std.option
import std.string
import std.test

// One `dependent -> dependency` edge, by module index. Edges naming a module outside the set (an
// unresolved import) are dropped by `demand_order`.
pub type ImportEdge = struct {
    from: usize
    to: usize
}

// Per-node Tarjan bookkeeping. `index` is the DFS discovery number and `UNVISITED` marks a node the
// walk has not reached; `low` is the lowest discovery number reachable from the node's subtree, and
// a node whose `low` equals its own `index` is the root of a component.
const UNVISITED: usize = 0xFFFF_FFFF_FFFF_FFFF

// The state of one Tarjan walk over `count` modules: the adjacency rows, the per-node discovery
// numbers and low links, the DFS stack, and the order being emitted. Scratch for `demand_order`,
// which hands `out` to its caller and frees the rest. One allocator serves every field.
type Tarjan = struct {
    adj: UnmanagedList(UnmanagedList(usize))
    index: UnmanagedList(usize)
    low: UnmanagedList(usize)
    on_stack: UnmanagedList(bool)
    stack: UnmanagedList(usize)
    next_index: usize
    out: UnmanagedList(usize)
    // The one allocator every field allocates through.
    allocator: &Allocator
}

// Frees every field, the adjacency rows included.
fn deinit(self: &Tarjan) {
    for &row in self.adj {
        row.deinit(self.allocator)
    }
    self.adj.deinit(self.allocator)
    self.index.deinit(self.allocator)
    self.low.deinit(self.allocator)
    self.on_stack.deinit(self.allocator)
    self.stack.deinit(self.allocator)
    self.out.deinit(self.allocator)
}

// The order to visit `count` modules in. `fqns[i]` names module `i` and is the tie-break inside a
// component; `edges` are dependent -> dependency.
//
// Every module appears exactly once, so the result is a permutation of `0..count` whatever the
// edges say.
pub fn demand_order(count: usize, fqns: &List(String), edges: &List(ImportEdge),
    allocator: &Allocator? = null) List(usize) {
    const alloc = allocator.or_global()
    let t = Tarjan {
        adj = build_adjacency(count, fqns, edges, alloc),
        index = filled_unmanaged_list(count, UNVISITED, alloc),
        low = filled_unmanaged_list(count, UNVISITED, alloc),
        on_stack = filled_unmanaged_list(count, false, alloc),
        stack = unmanaged_list(count, alloc),
        next_index = 0,
        out = unmanaged_list(count, alloc),
        allocator = alloc,
    }
    // Roots in FQN order, so a disconnected module set is still deterministic.
    let roots = by_fqn(count, fqns, alloc)
    defer roots.deinit()
    for r in roots {
        if t.index[r] == UNVISITED {
            visit(&t, r, fqns)
        }
    }
    // The order goes to the caller as a list over the same allocator; everything else was scratch.
    // Leaving an empty list behind keeps `deinit` free to release every field it owns.
    let out: List(usize) = .{ __storage = t.out, allocator = alloc }
    let empty: UnmanagedList(usize)
    t.out = empty
    t.deinit()
    return out
}

// Returns the successors of each node, one row per node, deduplicated and in FQN order. Edges
// naming a module outside `0..count` and self-edges are dropped.
fn build_adjacency(count: usize, fqns: &List(String), edges: &List(ImportEdge),
    allocator: &Allocator) UnmanagedList(UnmanagedList(usize)) {
    let adj: UnmanagedList(UnmanagedList(usize)) = unmanaged_list(count, allocator)
    for _i in 0..count {
        let row: UnmanagedList(usize)
        adj.push(row, allocator)
    }
    for e in edges {
        if e.from >= count or e.to >= count {
            continue
        }
        if e.from == e.to {
            continue
        }
        let row = &adj[e.from]
        if !row.contains(e.to) {
            row.push(e.to, allocator)
        }
    }
    for &row in adj {
        row.sort_by(fn(i) { name_of(fqns, i) })
    }
    return adj
}

fn visit(t: &Tarjan, v: usize, fqns: &List(String)) {
    t.index[v] = t.next_index
    t.low[v] = t.next_index
    t.next_index = t.next_index + 1
    t.stack.push(v, t.allocator)
    t.on_stack[v] = true

    for w in t.adj[v] {
        if t.index[w] == UNVISITED {
            visit(t, w, fqns)
            if t.low[w] < t.low[v] {
                t.low[v] = t.low[w]
            }
            continue
        }
        // Already on the stack means `w` is in the component being built; already popped means a
        // finished component, which must not pull this node's `low` back down.
        if t.on_stack[w] and t.index[w] < t.low[v] {
            t.low[v] = t.index[w]
        }
    }

    if t.low[v] != t.index[v] {
        return
    }
    let comp: List(usize) = list(4, t.allocator)
    loop {
        let w = t.stack.pop().unwrap()
        t.on_stack[w] = false
        comp.push(w)
        if w == v {
            break
        }
    }
    comp.sort_by(fn(i) { name_of(fqns, i) })
    for m in comp {
        t.out.push(m, t.allocator)
    }
    comp.deinit()
}

// Returns every index in `0..count`, ordered by the name it maps to.
fn by_fqn(count: usize, fqns: &List(String), allocator: &Allocator) List(usize) {
    let all: List(usize) = list(count, allocator)
    for i in 0..count {
        all.push(i)
    }
    all.sort_by(fn(i) { name_of(fqns, i) })
    return all
}

// The key `sort_by` orders indices with. An index with no name sorts first, and ties among such
// indices keep their relative order - `sort_by` is stable, so they stay deterministic.
fn name_of(fqns: &List(String), i: usize) String {
    if i >= fqns.len {
        return ""
    }
    return fqns[i]
}

// Tests

fn names(xs: String[]) List(String) {
    let l = list(xs.len)
    l.push_all(xs)
    return l
}

fn edge(from: usize, to: usize) ImportEdge {
    return ImportEdge { from = from, to = to }
}

fn position_of(order: &List(usize), v: usize) usize {
    for i in 0..order.len {
        if order[i] == v {
            return i
        }
    }
    return order.len
}

test "a dependency is visited before its dependent" {
    // c <- b <- a  (a imports b imports c)
    let fqns = names(["a", "b", "c"])
    defer fqns.deinit()
    let es = list(2)
    defer es.deinit()
    es.push(edge(0, 1))
    es.push(edge(1, 2))
    let order = demand_order(3, &fqns, &es)
    defer order.deinit()
    assert_eq(order.len, 3 as usize, "every module is visited once")
    assert_true(position_of(&order, 2) < position_of(&order, 1), "c before b")
    assert_true(position_of(&order, 1) < position_of(&order, 0), "b before a")
}

test "a cycle is one component, ordered by fqn inside it" {
    // b <-> c, both depended on by a. No topological order exists inside the cycle, so the
    // tie-break is the name.
    let fqns = names(["a", "c", "b"])
    defer fqns.deinit()
    let es = list(3)
    defer es.deinit()
    es.push(edge(0, 1))
    es.push(edge(1, 2))
    es.push(edge(2, 1))
    let order = demand_order(3, &fqns, &es)
    defer order.deinit()
    assert_eq(order.len, 3 as usize, "a cycle does not lose or repeat a module")
    // Index 2 is "b", index 1 is "c" - the component emits them by name.
    assert_true(position_of(&order, 2) < position_of(&order, 1), "b before c inside the component")
    assert_true(position_of(&order, 1) < position_of(&order, 0),
        "the whole cycle before its dependent")
}

test "a self-import is not a cycle" {
    let fqns = names(["a", "b"])
    defer fqns.deinit()
    let es = list(2)
    defer es.deinit()
    es.push(edge(0, 0))
    es.push(edge(0, 1))
    let order = demand_order(2, &fqns, &es)
    defer order.deinit()
    assert_eq(order.len, 2 as usize, "both modules present")
    assert_true(position_of(&order, 1) < position_of(&order, 0), "b before a")
}

test "order does not depend on the order edges were discovered" {
    let fqns = names(["a", "b", "c", "d"])
    defer fqns.deinit()
    let forward = list(3)
    defer forward.deinit()
    forward.push(edge(0, 1))
    forward.push(edge(1, 2))
    forward.push(edge(0, 3))
    let backward = list(3)
    defer backward.deinit()
    backward.push(edge(0, 3))
    backward.push(edge(1, 2))
    backward.push(edge(0, 1))

    let a = demand_order(4, &fqns, &forward)
    defer a.deinit()
    let b = demand_order(4, &fqns, &backward)
    defer b.deinit()
    for i in 0..a.len {
        assert_eq(a[i], b[i], "the same graph yields the same order")
    }
}

test "an unresolved import is dropped, not fatal" {
    let fqns = names(["a", "b"])
    defer fqns.deinit()
    let es = list(2)
    defer es.deinit()
    es.push(edge(0, 7))
    es.push(edge(0, 1))
    let order = demand_order(2, &fqns, &es)
    defer order.deinit()
    assert_eq(order.len, 2 as usize, "an out-of-range edge does not lose a module")
    assert_true(position_of(&order, 1) < position_of(&order, 0), "the real edge still orders")
}

test "a module nothing imports still appears exactly once" {
    let fqns = names(["z", "y"])
    defer fqns.deinit()
    let es = list(0)
    defer es.deinit()
    let order = demand_order(2, &fqns, &es)
    defer order.deinit()
    assert_eq(order.len, 2 as usize, "both isolated modules present")
    // Roots are entered by name: "y" (index 1) before "z" (index 0).
    assert_eq(order[0], 1 as usize, "isolated modules come in fqn order")
    assert_eq(order[1], 0 as usize, "isolated modules come in fqn order")
}
