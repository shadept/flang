// Standard libray support for the Option type.
// Along with re-exporting core.option.Option, the standard library offers
// functions to interact with the Option type.

import core.option

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

// Null-coalescing operator: Option(T) ?? T -> T
// Returns the inner value if present, otherwise returns the fallback value.
pub fn op_coalesce(opt: Option($T), fallback: T) T {
    if (opt.has_value) {
        return opt.value
    }
    return fallback
}

// Null-coalescing operator: Option(T) ?? Option(T) -> Option(T)
// Returns the first option if it has a value, otherwise returns the second.
pub fn op_coalesce(first: Option($T), second: Option(T)) Option(T) {
    if (first.has_value) {
        return first
    }
    return second
}
