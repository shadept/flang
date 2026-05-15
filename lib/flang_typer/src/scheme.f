// Scheme — `forall {vars}. body`. Polymorphism is a property of
// bindings (function signatures, let-generalised locals), not of the
// `Ty` itself, so this lives in its own module and `Ty` stays a
// monotype.
//
// Quantifier sets are `Set(VarId)` — `VarId` is a `u32` alias so the
// default `hash` works without any custom overload.
//
// Generalisation collects free variables of `body` whose `level` is
// deeper than the engine's current `enter_level`/`exit_level` cursor.
// Specialisation produces a fresh monotype where every quantified id
// has been replaced by an engine-fresh `Var`.

import std.allocator
import std.list
import std.option
import std.set
import flang_typer.type

// `forall {quantified}. body`. A scheme with empty `quantified` is
// monomorphic — `specialize` short-circuits.
pub type Scheme = struct {
    quantified: Set(VarId)
    body: Ty
}

// Construct a monomorphic scheme around `body`. `allocator` is used
// only for the empty `quantified` set's lazy backing storage.
pub fn mono(body: Ty, allocator: &Allocator? = null) Scheme {
    let q: Set(VarId) = set(allocator)
    return .{ quantified = q, body = body }
}

// Monomorphic — `quantified.len == 0`. A `Scheme` is the engine's
// canonical "binding" type even for monotypes; this predicate covers
// the let-binding fast path.
pub fn is_monomorphic(self: &Scheme) bool {
    return self.quantified.len() == 0
}

// Walk `body` collecting the ids of every free `TyVar` whose `level`
// is strictly greater than `cursor`. Variables at-or-shallower than the
// cursor were bound in an enclosing scope and must not be quantified.
//
// Resolution is the caller's job: pass an already-resolved `body`
// (`engine.resolve(body)`) so chains of bound vars don't show up as
// free here.
pub fn free_vars(body: &Ty, cursor: Level, out: &Set(VarId)) {
    body.* match {
        Var(v) => {
            if v.level > cursor {
                out.add(v.id)
            }
        },
        Prim(_) => {},
        Ref(inner) => free_vars(inner, cursor, out),
        Array(arr) => free_vars(arr.elem, cursor, out),
        Func(fn_ty) => {
            for i in 0..fn_ty.params.len {
                let p = &fn_ty.params[i]
                free_vars(p, cursor, out)
            }
            free_vars(fn_ty.ret, cursor, out)
        },
        Tuple(elems) => {
            for i in 0..elems.len {
                let e = &elems[i]
                free_vars(e, cursor, out)
            }
        },
        Record(fields) => {
            for i in 0..fields.len {
                let f = &fields[i]
                free_vars(&f.ty, cursor, out)
            }
        },
        Nominal(nr) => {
            for i in 0..nr.args.len {
                let a = &nr.args[i]
                free_vars(a, cursor, out)
            }
        },
        Never => {},
        Void => {},
        Error => {},
    }
}
