// Standard libray support for the Option type.
// Along with re-exporting core.option.Option, the standard library offers
// functions to interact with the Option type.

import core.option

pub fn is_some(self: Option($T)) bool {
    return self.has_value
}

pub fn is_none(self: Option($T)) bool {
    return self.has_value == false
}

pub fn expect(self: Option($T), msg: String) T {
    if (self.has_value) {
        return self.value
    }
    panic(msg)
    const fake: T // zero init
    fake
}

pub fn unwrap_or(self: Option($T), fallback: T) T {
    if (self.has_value) {
        return self.value
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
