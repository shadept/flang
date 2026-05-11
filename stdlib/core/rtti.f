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
    type_params: String[]
    type_args: &TypeInfo[]
    fields: FieldInfo[]
    params: ParamInfo[]
    return_type: &TypeInfo
}

pub type FieldInfo = struct {
    name: String
    offset: usize
    type_info: &TypeInfo
}

pub fn type_of(t: Type($T)) TypeInfo {
    return t // auto coersed to TypeInfo
}

pub fn size_of(t: Type($T)) usize {
    return t.size
}

pub fn align_of(t: Type($T)) usize {
    return t.align
}

// Project metadata, sourced from the flang.toml of the project a call site
// lexically lives in. The compiler intercepts `project_info()` during
// lowering and substitutes a constant for that project's name and version;
// the body below is never actually executed.
//
// Each library and binary gets its own answer: `project_info()` called
// inside flang_parser returns flang_parser's metadata; the same call
// inside a consumer project returns the consumer's. Stdlib call sites
// receive `("stdlib", "")` as a fallback.
pub type ProjectInfo = struct {
    name: String
    version: String
}

pub fn project_info() ProjectInfo {
    return .{ name = "", version = "" }
}
