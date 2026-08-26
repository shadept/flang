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
import std.list
import std.option
import std.set
import flang_typer.type
import flang_typer.interner

// `forall {quantified}. body`. A scheme with empty `quantified` is monomorphic - `specialize`
// short-circuits.
pub type Scheme = struct {
    quantified: Set(VarId)
    body: Ty
}

// Construct a monomorphic scheme around `body`. `allocator` is used only for the empty `quantified`
// set's lazy backing storage.
pub fn mono(body: Ty, allocator: &Allocator? = null) Scheme {
    let q: Set(VarId) = set(allocator)
    return .{ quantified = q, body = body }
}

// Monomorphic - `quantified.len == 0`. A `Scheme` is the engine's canonical "binding" type even for
// monotypes; this predicate covers the let-binding fast path.
pub fn is_monomorphic(self: &Scheme) bool {
    return self.quantified.len() == 0
}

// Walk `body`'s node graph collecting the ids of every free `TyVar` whose `level` is strictly
// greater than `cursor`. Variables at-or-shallower than the cursor were bound in an enclosing scope
// and must not be quantified. A ground subtree cites no vars - skipped.
//
// Resolution is the caller's job: pass an already-zonked `body` so chains of bound vars don't show
// up as free here.
pub fn free_vars(it: &TypeInterner, body: Ty, cursor: Level, out: &Set(VarId)) {
    if it.is_ground(body) {
        return
    }
    it.node(body) match {
        NVar(v) => {
            if v.level > cursor {
                out.add(v.id)
            }
        }
        NRef(inner) => free_vars(it, inner, cursor, out)
        NArray(arr) => free_vars(it, arr.elem, cursor, out)
        NFunc(f) => {
            for p in it.child_ids(f.params) {
                free_vars(it, p, cursor, out)
            }
            free_vars(it, f.ret, cursor, out)
        }
        NTuple(span) => {
            for e in it.child_ids(span) {
                free_vars(it, e, cursor, out)
            }
        }
        NRecord(rec) => {
            for t in it.child_ids(rec.tys) {
                free_vars(it, t, cursor, out)
            }
        }
        NNominal(nn) => {
            for a in it.child_ids(nn.args) {
                free_vars(it, a, cursor, out)
            }
        }
        _ => {}
    }
}
