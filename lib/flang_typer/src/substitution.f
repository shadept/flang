// Substitution — replace `Var(id)` occurrences inside a `Ty` with
// the corresponding entry from a `Dict(VarId, Ty)`. Pure: no engine
// state, no diagnostics. Used by `specialize`, by generic-function
// instantiation, and by `Ty` zonking when a fresh monotype is needed.
//
// All allocator-bearing operations (boxing the inner `Ty` for
// `Ref`/`Array.elem`/`Func.ret`, growing the `List`/`Dict` backing
// storage) accept an allocator explicitly because this module has no
// other state. The engine wires its own allocator through when
// substituting; tests can pass any.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import flang_typer.type

// Apply `subst` to `ty`. Each `Var(v)` with `v.id` in `subst` becomes
// the mapped type; everything else recurses structurally. Returns a
// fresh `Ty` value — `ty` is not mutated.
//
// `allocator` is used to box new `Ref`/`Array.elem`/`Func.ret` payloads
// and to grow returned `List` storage. Callers should pass the engine's
// allocator so substituted types share its arena lifetime.
pub fn substitute(ty: &Ty, subst: &Dict(VarId, Ty), allocator: &Allocator? = null) Ty {
    let alloc = allocator.or_global()
    return ty.* match {
        Var(v) => substitute_var(&v, subst),
        Prim(p) => Ty.Prim(p),
        Ref(inner) => substitute_ref(inner, subst, alloc),
        Array(arr) => substitute_array(&arr, subst, alloc),
        Func(fn_ty) => substitute_func(&fn_ty, subst, alloc),
        Tuple(elems) => substitute_tuple(&elems, subst, alloc),
        Record(fields) => substitute_record(&fields, subst, alloc),
        Nominal(nr) => substitute_nominal(&nr, subst, alloc),
        Never => Ty.Never,
        Void => Ty.Void,
        Error => Ty.Error,
    }
}

fn substitute_var(v: &TyVar, subst: &Dict(VarId, Ty)) Ty {
    return subst.get(v.id) match {
        Some(replacement) => replacement,
        None => Ty.Var(v.*),
    }
}

fn substitute_ref(inner: &Ty, subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    let new_inner = substitute(inner, subst, alloc)
    let boxed = box(alloc, new_inner)
    return Ty.Ref(boxed)
}

fn substitute_array(arr: &ArrayTy, subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    let new_elem = substitute(arr.elem, subst, alloc)
    let boxed = box(alloc, new_elem)
    return Ty.Array(.{ elem = boxed, length = arr.length })
}

fn substitute_func(fn_ty: &FunctionTy, subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    let new_params = list(fn_ty.params.len, alloc)
    for i in 0..fn_ty.params.len {
        let p = &fn_ty.params[i]
        new_params.push(substitute(p, subst, alloc))
    }
    let new_ret = substitute(fn_ty.ret, subst, alloc)
    let boxed_ret = box(alloc, new_ret)
    return Ty.Func(.{ params = new_params, ret = boxed_ret })
}

fn substitute_tuple(elems: &List(Ty), subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    let new_elems = list(elems.len, alloc)
    for i in 0..elems.len {
        let e = &elems[i]
        new_elems.push(substitute(e, subst, alloc))
    }
    return Ty.Tuple(new_elems)
}

fn substitute_record(fields: &List(Field), subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    let new_fields = list(fields.len, alloc)
    for i in 0..fields.len {
        let f = &fields[i]
        let new_ty = substitute(&f.ty, subst, alloc)
        new_fields.push(.{ name = f.name, ty = new_ty })
    }
    return Ty.Record(new_fields)
}

fn substitute_nominal(nr: &NominalRef, subst: &Dict(VarId, Ty), alloc: &Allocator) Ty {
    if nr.args.len == 0 {
        return Ty.Nominal(.{ id = nr.id, args = nr.args })
    }
    let new_args: List(Ty) = list(nr.args.len, alloc)
    for i in 0..nr.args.len {
        let a = &nr.args[i]
        new_args.push(substitute(a, subst, alloc))
    }
    return Ty.Nominal(.{ id = nr.id, args = new_args })
}
