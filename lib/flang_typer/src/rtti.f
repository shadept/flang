// The compiler-side view of `core.rtti.TypeInfo` over a resolved type: what the runtime descriptor
// reports and what a `#if` sees through `type_info(T)` / `type_of(v)`. One source for both, so a
// name compared at compile time is the name the descriptor carries.

import std.allocator
import std.option
import std.string

import flang_parser.comptime

import flang_typer.copyable
import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.type

// The name `TypeInfo.name` reports: a primitive's spelling, a nominal's SHORT name, and a
// structural rendering for the rest.
pub fn rtti_name(it: &TypeInterner, reg: &NominalRegistry, t: Ty) String {
    return it.node(t) match {
        NPrim(p) => prim_name(p)
        NVoid => "void"
        NNever => "never"
        NNominal(nn) => short_name(nominal_fqn(reg.get(nn.id)))
        NRef(_) => "reference"
        NArray(_) => "array"
        NFunc(_) => "function"
        NTuple(_) => "tuple"
        _ => ""
    }
}

fn short_name(fqn: String) String {
    return fqn.rfind('.') match {
        Some(i) => fqn[i + 1..fqn.len]
        None => fqn
    }
}

// `TypeKind`'s declaration index for `t` (Primitive, Array, Struct, Enum, Function - the declared
// values coincide with the indices).
pub fn rtti_kind(it: &TypeInterner, reg: &NominalRegistry, t: Ty) i32 {
    return it.node(t) match {
        NArray(_) => KIND_ARRAY
        NFunc(_) => KIND_FUNCTION
        NNominal(nn) => reg.get(nn.id).* match {
            NomStruct(_) => KIND_STRUCT
            NomEnum(_) => KIND_ENUM
        }
        _ => KIND_PRIMITIVE
    }
}

// The `type_info(T)` value of a type named in a `#if`, or the `type_of(v)` value of a value named
// there: name, kind and the copyable bit of the concrete `t`, no syntax behind it.
pub fn ct_type_info_of_ty(it: &TypeInterner, reg: &NominalRegistry, t: Ty,
    alloc: &Allocator?) CtTypeInfo {
    return CtTypeInfo {
        name = rtti_name(it, reg, t),
        kind = rtti_kind(it, reg, t),
        source = CtTypeSource.FromTy,
        copyable = Some(is_copyable_ty(it, reg, t, alloc)),
    }
}
