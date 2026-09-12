// Copyability - the derived bit behind `owned` (RFC-028), over resolved types.
//
// A type is non-copyable when releasing a resource rides in it: a field declared `owned`, or a
// field whose own type is non-copyable. Enum variant payloads count as fields; the payload
// propagates the bit but cannot declare it.
//
// References and function types are the leaves. A reference is how FLang shares a value rather than
// holds it, so it carries no release responsibility - which also makes the walk a post-order with
// no fixpoint: `check_recursive_nominal` poisons a by-value field cycle at E2035, so none survives
// into a walk, and every other cycle passes through a reference. `Slice` and `String` need no rule
// of their own: their only field of interest is a `&T`, so they come out copyable by the same
// reason a slice is a view.
//
// The walk takes the interner and the registry, not the engine: lowering fills
// `core.rtti.TypeInfo.copyable` from it with no engine at hand, and the engine's `is_copyable`
// resolves its variables first and delegates. A variable is a leaf here - it is diagnosed at the
// instantiation that pins it, never in the generic body.
//
// ponytail: recomputed per call, and every nominal hop builds a substitution dict. Memoize on a
// `List(u8)` parallel to the interner's nodes when a hot path starts asking.

import std.allocator
import std.collections.dict
import std.collections.list
import std.option

import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.type

pub fn is_copyable_ty(it: &TypeInterner, reg: &NominalRegistry, ty: Ty, alloc: &Allocator?) bool {
    return it.node(ty) match {
        NRef(_) => true
        NFunc(_) => true
        NVar(_) => true
        NArray(arr) => is_copyable_ty(it, reg, arr.elem, alloc)
        NTuple(span) => copyable_span(it, reg, span, alloc)
        NRecord(rec) => copyable_span(it, reg, rec.tys, alloc)
        NNominal(nn) => copyable_nominal(it, reg, &nn, alloc)
        _ => true
    }
}

fn copyable_span(it: &TypeInterner, reg: &NominalRegistry, span: ChildSpan,
    alloc: &Allocator?) bool {
    for i in 0..span.len {
        if !is_copyable_ty(it, reg, it.child_at(span, i), alloc) {
            return false
        }
    }
    return true
}

fn copyable_nominal(it: &TypeInterner, reg: &NominalRegistry, nn: &NNominalNode,
    alloc: &Allocator?) bool {
    return reg.get(nn.id).* match {
        NomStruct(sd) => copyable_struct(it, reg, &sd, nn, alloc)
        NomEnum(ed) => copyable_enum(it, reg, &ed, nn, alloc)
    }
}

fn copyable_struct(it: &TypeInterner, reg: &NominalRegistry, sd: &StructDef, nn: &NNominalNode,
    alloc: &Allocator?) bool {
    for i in 0..sd.fields.len {
        if sd.fields[i].owned {
            return false
        }
    }
    let subst = param_subst(it, &sd.type_params, nn.args, alloc)
    defer subst.deinit()
    for i in 0..sd.fields.len {
        const ft = it.substitute(sd.fields[i].ty, &subst, alloc)
        if !is_copyable_ty(it, reg, ft, alloc) {
            return false
        }
    }
    return true
}

fn copyable_enum(it: &TypeInterner, reg: &NominalRegistry, ed: &EnumDef, nn: &NNominalNode,
    alloc: &Allocator?) bool {
    let subst = param_subst(it, &ed.type_params, nn.args, alloc)
    defer subst.deinit()
    for vi in 0..ed.variants.len {
        for pi in 0..ed.variants[vi].payloads.len {
            const pt = it.substitute(ed.variants[vi].payloads[pi], &subst, alloc)
            if !is_copyable_ty(it, reg, pt, alloc) {
                return false
            }
        }
    }
    return true
}

// A declaration's field types are written against its own type parameters, so the instantiation's
// arguments have to go in before the walk sees `&FileHandle` where the source says `&$T`. A
// partially-applied nominal (fewer arguments than parameters) maps only what it has; the rest stay
// variables, which the walk treats as leaves.
pub fn param_subst(it: &TypeInterner, params: &List(VarId), args: ChildSpan,
    alloc: &Allocator?) Dict(VarId, Ty) {
    let subst: Dict(VarId, Ty) = dict(params.len, alloc)
    for i in 0..params.len {
        if i >= args.len {
            break
        }
        subst.set(params[i], it.child_at(args, i))
    }
    return subst
}
