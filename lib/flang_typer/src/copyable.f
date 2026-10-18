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
// resolves its variables first and delegates. A variable is a leaf here, copyable - it is diagnosed
// at the instantiation that pins it - except a rigid one, a generic body's own type parameter
// (RFC-029), which copies only under a `where T: copyable` bound.
//
// ponytail: recomputed per call, and every nominal hop builds a substitution dict. Memoize on a
// `List(u8)` parallel to the interner's nodes when a hot path starts asking.

import std.allocator
import std.collections.dict
import std.collections.list

import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.type

pub fn is_copyable_ty(
    it: &TypeInterner,
    reg: &NominalRegistry,
    ty: Ty,
    rigid: &Dict(VarId, bool)? = null,
) bool {
    return it.node(ty) match {
        NRef(_) => true
        NFunc(_) => true
        NVar(v) => rigid match {
            Some(r) => r.get(v.id) ?? true
            None => true
        }
        NArray(arr) => is_copyable_ty(it, reg, arr.elem, rigid)
        NTuple(span) => copyable_span(it, reg, span, rigid)
        NRecord(rec) => copyable_span(it, reg, rec.tys, rigid)
        NNominal(nn) => copyable_nominal(it, reg, ty, &nn, rigid)
        _ => true
    }
}

fn copyable_span(
    it: &TypeInterner,
    reg: &NominalRegistry,
    span: ChildSpan,
    rigid: &Dict(VarId, bool)?,
) bool {
    for i in 0..span.len {
        if !is_copyable_ty(it, reg, it.child_at(span, i), rigid) {
            return false
        }
    }
    return true
}

fn copyable_nominal(
    it: &TypeInterner,
    reg: &NominalRegistry,
    ty: Ty,
    nn: &NNominalNode,
    rigid: &Dict(VarId, bool)?,
) bool {
    return reg.get(nn.id).* match {
        NomStruct(sd) => copyable_struct(it, reg, ty, &sd, nn, rigid)
        NomEnum(ed) => copyable_enum(it, reg, ty, &ed, nn, rigid)
    }
}

fn copyable_struct(
    it: &TypeInterner,
    reg: &NominalRegistry,
    ty: Ty,
    sd: &StructDef,
    nn: &NNominalNode,
    rigid: &Dict(VarId, bool)?,
) bool {
    for i in 0..sd.fields.len {
        if sd.fields[i].owned {
            return false
        }
    }
    let subst = reg.instance_subst(ty, &sd.type_params, &sd.assoc_params, nn.args, it)
    defer subst.deinit()
    for i in 0..sd.fields.len {
        const ft = it.substitute(sd.fields[i].ty, &subst)
        if !is_copyable_ty(it, reg, ft, rigid) {
            return false
        }
    }
    return true
}

fn copyable_enum(
    it: &TypeInterner,
    reg: &NominalRegistry,
    ty: Ty,
    ed: &EnumDef,
    nn: &NNominalNode,
    rigid: &Dict(VarId, bool)?,
) bool {
    let subst = reg.instance_subst(ty, &ed.type_params, &ed.assoc_params, nn.args, it)
    defer subst.deinit()
    for vi in 0..ed.variants.len {
        for pi in 0..ed.variants[vi].payloads.len {
            const pt = it.substitute(ed.variants[vi].payloads[pi], &subst)
            if !is_copyable_ty(it, reg, pt, rigid) {
                return false
            }
        }
    }
    return true
}
