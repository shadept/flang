// Core optional value support. This module establishes the canonical
// Option(T) layout so frontends, the type solver, and the standard library
// can agree on binary representations. The preferred surface syntax uses
// `T?` and `null`, but the underlying type is declared here for codegen.

pub struct Option(T) {
    has_value: bool
    value: T
}

pub fn is_some(value: Option($T)) bool {
    return value.has_value
}

pub fn is_none(value: Option($T)) bool {
    return value.has_value == false
}

pub fn unwrap_or(value: Option($T), fallback: T) T {
    if (value.has_value) {
        return value.value
    }
    return fallback
}
