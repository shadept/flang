// Scheme - `forall {vars}. body`. Polymorphism is a property of bindings (function signatures,
// let-generalised locals), not of the `Ty` itself, so this lives in its own module and `Ty` stays a
// monotype handle.
//
// Quantifier sets are `Set(VarId)` - `VarId` is a `u32` alias so the default `hash` works without
// any custom overload.
//
// Generalisation collects free variables of `body` whose `level` is deeper than the engine's
// current `enter_level`/`exit_level` cursor. Specialisation produces a fresh monotype where every
// quantified id has been replaced by an engine-fresh `Var`.

import std.allocator
import std.collections.list
import std.collections.set

import flang_typer.interner
import flang_typer.type

// `forall {quantified}. body`. A scheme with empty `quantified` is monomorphic - `specialize`
// short-circuits.
pub type Scheme = struct {
    quantified: Set(VarId)
    body: Ty
}

// The quantified set is the scheme's own; the body is a handle into the type table.
pub fn deinit(self: move Scheme) {
    self.quantified.deinit()
}

// An independent copy: the quantified set is rebuilt, the body handle shared.
pub fn clone(self: &Scheme) Scheme {
    let q: Set(VarId) = set()
    for v in self.quantified {
        q.add(v)
    }
    return .{ quantified = move q, body = self.body }
}

// Construct a monomorphic scheme around `body`. `allocator` is used only for the empty `quantified`
// set's lazy backing storage.
pub fn mono(body: Ty) Scheme {
    let q: Set(VarId) = set()
    return .{ quantified = move q, body = body }
}

// Monomorphic - `quantified.len == 0`. A `Scheme` is the engine's canonical "binding" type even for
// monotypes; this predicate covers the let-binding fast path.
pub fn is_monomorphic(self: &Scheme) bool {
    return self.quantified.len() == 0
}

// Every `TyVar` node `body` names, in first-occurrence order, each once in `out`. Pass a zonked
// `body`.
pub fn var_nodes(it: &TypeInterner, body: Ty, out: &List(Ty)) {
    walk_vars(it, body, VarSink.Ordered(out))
}

// Walk `body`'s node graph collecting the ids of every free `TyVar` whose `level` is strictly
// greater than `cursor`. Variables at-or-shallower than the cursor were bound in an enclosing scope
// and must not be quantified. A ground subtree cites no vars - skipped.
//
// Resolution is the caller's job: pass an already-zonked `body` so chains of bound vars don't show
// up as free here.
pub fn free_vars(it: &TypeInterner, body: Ty, cursor: Level, out: &Set(VarId)) {
    walk_vars(it, body, VarSink.Deeper(cursor, out))
}

// Where `walk_vars` puts the variables it meets.
type VarSink = enum {
    // The ids of those deeper than the level.
    Deeper(Level, &Set(VarId))
    // The nodes, in first-occurrence order, each once.
    Ordered(&List(Ty))
}

fn walk_vars(it: &TypeInterner, body: Ty, sink: VarSink) {
    if it.is_ground(body) {
        return
    }
    it.node(body) match {
        NVar(v) => sink match {
            Deeper(cursor, out) => {
                if v.level > cursor {
                    out.add(v.id)
                }
            }
            Ordered(out) => {
                if !out.contains(body) {
                    out.push(body)
                }
            }
        }
        NRef(inner) => walk_vars(it, inner, sink)
        NArray(arr) => walk_vars(it, arr.elem, sink)
        NFunc(f) => {
            for p in it.child_ids(f.params) {
                walk_vars(it, p, sink)
            }
            walk_vars(it, f.ret, sink)
        }
        NTuple(span) => {
            for e in it.child_ids(span) {
                walk_vars(it, e, sink)
            }
        }
        NRecord(rec) => {
            for t in it.child_ids(rec.tys) {
                walk_vars(it, t, sink)
            }
        }
        NNominal(nn) => {
            for a in it.child_ids(nn.args) {
                walk_vars(it, a, sink)
            }
        }
        _ => {}
    }
}
