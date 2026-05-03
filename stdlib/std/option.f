// Standard library support for the Option type.
// Along with re-exporting core.option.Option, the standard library offers
// functions to interact with the Option type.

import core.option

pub fn is_some(self: Option($T)) bool {
    return self match {
        Some(_) => true,
        None => false,
    }
}

pub fn is_none(self: Option($T)) bool {
    return self match {
        Some(_) => false,
        None => true,
    }
}

pub fn map(self: Option($T), f: fn(T) $U) Option(U) {
    return self match {
        Some(v) => Some(f(v)),
        None => None,
    }
}

pub fn expect(self: Option($T), msg: String) T {
    return self match {
        Some(v) => v,
        None => {
            panic(msg)
            const fake: T // zero init, unreachable
            fake
        },
    }
}

// Unwrap the Some payload, panicking on None. Use `unwrap_or` / `match` when
// None is reachable; reserve `unwrap` for invariants you've already checked
// (e.g. inside an `if x.is_some()` branch).
pub fn unwrap(self: Option($T)) T {
    return self match {
        Some(v) => v,
        None => {
            panic("called `unwrap` on a `None` value")
            const fake: T // zero init, unreachable
            fake
        },
    }
}

pub fn unwrap_or(self: Option($T), fallback: T) T {
    return self match {
        Some(v) => v,
        None => fallback,
    }
}

// Null-coalescing operator: Option(T) ?? T -> T
// Returns the inner value if present, otherwise returns the fallback value.
pub fn op_coalesce(opt: Option($T), fallback: T) T {
    return opt match {
        Some(v) => v,
        None => fallback,
    }
}

// Null-coalescing operator: Option(T) ?? Option(T) -> Option(T)
// Returns the first option if it has a value, otherwise returns the second.
pub fn op_coalesce(first: Option($T), second: Option(T)) Option(T) {
    return first match {
        Some(_) => first,
        None => second,
    }
}
