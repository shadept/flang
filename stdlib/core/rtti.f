// Runtime type introspection functions
// These are regular FLang functions, not compiler intrinsics!

import core.slice
import core.string

pub type TypeKind = enum {
    Primitive = 0
    Array = 1
    Struct = 2
    Enum = 3
    Function = 4
}

// Generic alias for TypeInfo.
// Allows couple of T to its TypeInfo.
pub type Type = struct(T) {}

pub type ParamInfo = struct {
    name: String
    type_info: &TypeInfo
}

pub type TypeInfo = struct {
    name: String
    size: usize
    align: usize
    kind: TypeKind
    // The derived bit of RFC-028: false when the type, or anything it holds by value, declares an
    // `owned` field. `#if type_info(T).copyable` reads the same bit at compile time.
    copyable: bool
    type_params: String[]
    type_args: Slice(&TypeInfo)
    fields: FieldInfo[]
    variants: VariantInfo[]
    params: ParamInfo[]
    return_type: &TypeInfo
}

// One enum variant. Deliberately a struct, not a bare String: future members (payload, value) land
// here without changing `variants`' type.
pub type VariantInfo = struct {
    name: String
}

pub type FieldInfo = struct {
    name: String
    offset: usize
    type_info: &TypeInfo
}

// The descriptor of a type: `type_info(Point)`, `type_info(T)` in a generic body. Descriptors are
// static and one per type, so two `&TypeInfo` are the same type exactly when they are equal. The
// compiler substitutes the descriptor's address for every call; the body below never runs.
pub fn type_info(t: Type($T)) &TypeInfo {
    return 0usize as &TypeInfo
}

// The descriptor of a value's type: `type_of(x)`. For a type, use `type_info`.
pub fn type_of(value: $T) &TypeInfo {
    return type_info(T)
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}

// Project metadata, sourced from the flang.toml of the project a call site lexically lives in. The
// compiler intercepts `project_info()` during lowering and substitutes a constant for that
// project's name and version; the body below is never actually executed.
//
// Each library and binary gets its own answer: `project_info()` called inside flang_parser returns
// flang_parser's metadata; the same call inside a consumer project returns the consumer's. Stdlib
// call sites receive `("stdlib", "")` as a fallback.
pub type ProjectInfo = struct {
    name: String
    version: String
}

pub fn project_info() ProjectInfo {
    return .{ name = "", version = "" }
}
