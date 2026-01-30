// Core optional value support. This module establishes the canonical
// Option(T) layout so frontends, the type solver, and the standard library
// can agree on binary representations. The preferred surface syntax uses
// `T?` and `null`, but the underlying type is declared here for codegen.

pub struct Option(T) {
    has_value: bool
    value: T
}

pub fn op_eq(a: Option($T), b: Option(T)) bool {
    if (a.has_value != b.has_value) {
        return false
    }
    if (a.has_value) {
        return a.value == b.value
    }
    return true
}

pub fn op_ne(a: Option($T), b: Option(T)) bool {
    return !op_eq(a, b)
}
