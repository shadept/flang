// Ty - a 4-byte handle into the `TypeInterner` (RFC-024). One node is
// stored per distinct type, so equality of types IS equality of handles,
// copying a type copies an integer, and the interner is the single owner
// of every type's storage.
//
// The shape behind a handle is a `TyNode` (interner.f); consumers match
// on nodes through the table. This module keeps what needs no table:
// the handle itself, the identifier aliases, the fixed leaf ids, the
// primitive kinds and their predicates, and `Field` - the name/type pair
// records and nominal struct bodies share.
//
// `Error` is poison. Unification with `Error` on either side resolves
// to `Error` and emits no diagnostic, so a single upstream failure does
// not cascade.

import std.option
import std.string
import flang_core.span

// The type handle. Handed out by the `TypeInterner` in first-intern
// order; the leaf ids below are fixed by construction.
pub type Ty = u32

// Fixed leaf ids. Primitives follow at `TY_PRIM0` in `PrimitiveKind`
// declaration order (Bool .. Char) - `prim_of` is the mapping.
pub const TY_VOID: Ty = 0
pub const TY_NEVER: Ty = 1
pub const TY_ERROR: Ty = 2
pub const TY_PRIM0: Ty = 3

// ─────────────────────────────────────────────────────────────────────
// Handles - transparent aliases over plain integers so APIs read at a
// glance and the engine pays no wrapping overhead.
// ─────────────────────────────────────────────────────────────────────

// Inference-variable identifier. Allocated by the engine; opaque to
// callers. Two `TyVar`s with the same `VarId` are the same variable.
pub type VarId = u32

// Let-generalisation depth. Variables created at a deeper level than the
// current `enter_level`/`exit_level` cursor are eligible to be quantified
// by `generalize`.
pub type Level = u32

// Handle into the `NominalRegistry`. Stable across a single compilation.
pub type NominalId = u32

// ─────────────────────────────────────────────────────────────────────
// Inference variables
// ─────────────────────────────────────────────────────────────────────

// One unification variable. The `level` is metadata used by
// `generalize`/`specialize`; two vars are the same variable iff their
// `id`s match, but a var NODE keys on (id, level) - `free_vars` reads
// the level off the node.
pub type TyVar = struct {
    id: VarId
    level: Level
}

// ─────────────────────────────────────────────────────────────────────
// Primitives - tagged, not stringly typed
// ─────────────────────────────────────────────────────────────────────

// The 14 FLang scalar primitives. Compared by tag; no string names
// flow through the type system at runtime. Diagnostic rendering goes
// through `prim_name(...)`.
pub type PrimitiveKind = enum {
    Bool
    I8
    I16
    I32
    I64
    ISize
    U8
    U16
    U32
    U64
    USize
    F32
    F64
    Char
}

// The fixed handle of a primitive - no table involved.
pub fn prim_of(p: PrimitiveKind) Ty {
    const offset: u32 = p match {
        Bool => 0u32,
        I8 => 1u32, I16 => 2u32, I32 => 3u32, I64 => 4u32, ISize => 5u32,
        U8 => 6u32, U16 => 7u32, U32 => 8u32, U64 => 9u32, USize => 10u32,
        F32 => 11u32, F64 => 12u32, Char => 13u32,
    }
    return TY_PRIM0 + offset
}

// A name -> type pair used for `Record` (anonymous structs) and for
// nominal struct fields when the registry materialises them.
// `decl_span` locates the field's own declaration, and is `none_span()` for
// synthesized fields that have none (a closure's captured environment). It
// is metadata: node identity and rendering ignore it, so two records
// differing only in where they were written are the same type.
pub type Field = struct {
    name: String
    ty: Ty
    decl_span: SourceSpan
}

// ─────────────────────────────────────────────────────────────────────
// Handle predicates - table-free by the fixed-id contract.
// ─────────────────────────────────────────────────────────────────────

pub fn is_error(self: Ty) bool {
    return self == TY_ERROR
}

pub fn is_never(self: Ty) bool {
    return self == TY_NEVER
}

pub fn is_prim_ty(self: Ty) bool {
    return self >= TY_PRIM0 and self < TY_PRIM0 + 14
}

// Lower-case lexical name of a primitive - same spelling used in source
// for type annotations (`i32`, `bool`, `char`, …). Diagnostics for
// primitive types use this directly.
pub fn prim_name(p: PrimitiveKind) String {
    return p match {
        Bool => "bool",
        I8 => "i8",
        I16 => "i16",
        I32 => "i32",
        I64 => "i64",
        ISize => "isize",
        U8 => "u8",
        U16 => "u16",
        U32 => "u32",
        U64 => "u64",
        USize => "usize",
        F32 => "f32",
        F64 => "f64",
        Char => "char",
    }
}

// ─────────────────────────────────────────────────────────────────────
// Primitive predicates
// ─────────────────────────────────────────────────────────────────────

// Every primitive except `Bool`. Includes `Char` (a u32 codepoint).
pub fn is_numeric(p: PrimitiveKind) bool {
    return p match {
        Bool => false,
        _ => true,
    }
}

pub fn is_integer(p: PrimitiveKind) bool {
    return p match {
        I8 => true, I16 => true, I32 => true, I64 => true, ISize => true,
        U8 => true, U16 => true, U32 => true, U64 => true, USize => true,
        _ => false,
    }
}

pub fn is_signed_integer(p: PrimitiveKind) bool {
    return p match {
        I8 => true, I16 => true, I32 => true, I64 => true, ISize => true,
        _ => false,
    }
}

pub fn is_float(p: PrimitiveKind) bool {
    return p match {
        F32 => true, F64 => true,
        _ => false,
    }
}
