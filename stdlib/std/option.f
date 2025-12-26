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
