// Well-known constants — primitive `Ty` constructors and the FQN
// strings of nominal types the inference engine special-cases (Option,
// String, Slice, Range, the RTTI `Type(T)` handle, the project-info
// struct).
//
// Primitive constructors are `#inline` because they're called from hot
// paths in the checker (every literal, every annotation). FQN strings
// are `pub const` so the resolver can compare against them by `String`
// value-equality without allocating.

import std.string
import flang_typer.type

// ─────────────────────────────────────────────────────────────────────
// Primitive `Ty` constructors
//
// Returning by value is cheap — `Ty` is a tagged union with all
// fixed-size payloads, so each call boils down to one struct return.
// No allocation, no engine state.
// ─────────────────────────────────────────────────────────────────────

#inline pub fn ty_bool() Ty { return Ty.Prim(PrimitiveKind.Bool) }
#inline pub fn ty_i8() Ty { return Ty.Prim(PrimitiveKind.I8) }
#inline pub fn ty_i16() Ty { return Ty.Prim(PrimitiveKind.I16) }
#inline pub fn ty_i32() Ty { return Ty.Prim(PrimitiveKind.I32) }
#inline pub fn ty_i64() Ty { return Ty.Prim(PrimitiveKind.I64) }
#inline pub fn ty_isize() Ty { return Ty.Prim(PrimitiveKind.ISize) }
#inline pub fn ty_u8() Ty { return Ty.Prim(PrimitiveKind.U8) }
#inline pub fn ty_u16() Ty { return Ty.Prim(PrimitiveKind.U16) }
#inline pub fn ty_u32() Ty { return Ty.Prim(PrimitiveKind.U32) }
#inline pub fn ty_u64() Ty { return Ty.Prim(PrimitiveKind.U64) }
#inline pub fn ty_usize() Ty { return Ty.Prim(PrimitiveKind.USize) }
#inline pub fn ty_f32() Ty { return Ty.Prim(PrimitiveKind.F32) }
#inline pub fn ty_f64() Ty { return Ty.Prim(PrimitiveKind.F64) }
#inline pub fn ty_char() Ty { return Ty.Prim(PrimitiveKind.Char) }
#inline pub fn ty_never() Ty { return Ty.Never }
#inline pub fn ty_void() Ty { return Ty.Void }
#inline pub fn ty_error() Ty { return Ty.Error }

// Map a primitive lexical name (as it appears in source: "i32", "bool",
// …) to its `PrimitiveKind`. Returns `None` for any other identifier.
// Used by the type resolver when turning a `NamedType` AST node into
// a `Ty`.
pub fn prim_from_name(name: String) PrimitiveKind? {
    return name match {
        "bool" => Some(PrimitiveKind.Bool),
        "i8" => Some(PrimitiveKind.I8),
        "i16" => Some(PrimitiveKind.I16),
        "i32" => Some(PrimitiveKind.I32),
        "i64" => Some(PrimitiveKind.I64),
        "isize" => Some(PrimitiveKind.ISize),
        "u8" => Some(PrimitiveKind.U8),
        "u16" => Some(PrimitiveKind.U16),
        "u32" => Some(PrimitiveKind.U32),
        "u64" => Some(PrimitiveKind.U64),
        "usize" => Some(PrimitiveKind.USize),
        "f32" => Some(PrimitiveKind.F32),
        "f64" => Some(PrimitiveKind.F64),
        "char" => Some(PrimitiveKind.Char),
        _ => None,
    }
}

// ─────────────────────────────────────────────────────────────────────
// Well-known nominal FQNs
//
// The inference engine special-cases these for sugar resolution
// (`T?` → `Option(T)`, string literals → `String`, array decay → `Slice`,
// `Type(T)` RTTI handles, etc.) and for the project-info intrinsic.
// Diagnostics also use them to format type aliases and sugar back into
// their surface forms.
// ─────────────────────────────────────────────────────────────────────

pub const FQN_STRING: String = "core.string.String"
pub const FQN_OPTION: String = "core.option.Option"
pub const FQN_TRY_RESULT: String = "core.try.TryResult"
pub const FQN_SLICE: String = "core.slice.Slice"
pub const FQN_RANGE: String = "core.range.Range"
pub const FQN_TYPE: String = "core.rtti.Type"
pub const FQN_RTTI_PREFIX: String = "core.rtti."
pub const FQN_PROJECT_INFO: String = "core.rtti.ProjectInfo"
pub const FQN_PROJECT_INFO_FN: String = "project_info"
pub const FQN_RTTI_MODULE: String = "core.rtti"
