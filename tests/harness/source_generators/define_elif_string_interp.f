//! TEST: define_elif_string_interp
//! EXIT: 0

// `#elif` chains and `"#(x)"` string-literal interpolation; `Ident` params
// are identifiers with `.text`; `Type` params are TypeInfo (`T.kind`).

import core.rtti

type Pt = struct {
    x: i32
    y: i32
}

type Mode = enum { Fast Slow }

#define(kind_name, T: Type, Name: Ident) {
    #if T.kind == TypeKind.Struct {
        fn #(Name)() String { return "#(T.name) is a struct with #(T.fields.len) fields" }
    } #elif T.kind == TypeKind.Enum {
        fn #(Name)() String { return "#(T.name) is an enum with #(T.variants.len) variants" }
    } #else {
        fn #(Name)() String { return "#(T.name) is #(Name.text)" }
    }
}

#kind_name(Pt, describe_pt)
#kind_name(Mode, describe_mode)
#kind_name(i32, describe_i32)

pub fn main() i32 {
    if describe_pt() != "Pt is a struct with 2 fields" { return 1 }
    if describe_mode() != "Mode is an enum with 2 variants" { return 2 }
    if describe_i32() != "i32 is describe_i32" { return 3 }
    return 0
}
