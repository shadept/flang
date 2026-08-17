// Standard library support for the Option type.
// Along with re-exporting core.option.Option, the standard library offers
// functions to interact with the Option type.

import core.option
import std.test

pub fn is_some(self: Option($T)) bool {
    return self match {
        Some(_) => true
        None => false
    }
}

pub fn is_none(self: Option($T)) bool {
    return self match {
        Some(_) => false
        None => true
    }
}

// Apply `f` to a present value, leaving `None` untouched. Use it to
// transform what an optional holds without unwrapping and re-wrapping; `f`
// never runs on `None`. When `f` itself returns an `Option`, use `flat_map`
// so the result does not nest.
pub fn map(self: Option($T), f: fn(T) $U) Option(U) {
    return self match {
        Some(v) => Some(f(v))
        None => None
    }
}

// `map` for a function that itself yields an `Option`, flattening the
// result. Chains a fallible step onto a fallible one: passing such a
// function to `map` would give `Option(Option(U))`, whereas this stays one
// level deep. `None` short-circuits and `f` never runs.
pub fn flat_map(self: Option($T), f: fn(T) Option($U)) Option(U) {
    return self match {
        Some(v) => f(v)
        None => None
    }
}

pub fn expect(self: Option($T), msg: String) T {
    return self match {
        Some(v) => v
        None => panic(msg)
    }
}

// Unwrap the Some payload, panicking on None. Use `unwrap_or` / `match` when
// None is reachable; reserve `unwrap` for invariants you've already checked
// (e.g. inside an `if x.is_some()` branch).
pub fn unwrap(self: Option($T)) T {
    return self match {
        Some(v) => v
        None => panic("called `unwrap` on a `None` value")
    }
}

pub fn unwrap_or(self: Option($T), fallback: T) T {
    return self match {
        Some(v) => v
        None => fallback
    }
}

// Null-coalescing operator: Option(T) ?? T -> T
// Returns the inner value if present, otherwise returns the fallback value.
pub fn op_coalesce(opt: Option($T), fallback: T) T {
    return opt match {
        Some(v) => v
        None => fallback
    }
}

// Null-coalescing operator: Option(T) ?? Option(T) -> Option(T)
// Returns the first option if it has a value, otherwise returns the second.
pub fn op_coalesce(first: Option($T), second: Option(T)) Option(T) {
    return first match {
        Some(_) => first
        None => second
    }
}

test "map transforms a present value and passes None through" {
    let some: Option(i32) = Some(21)
    let none: Option(i32) = null
    assert_eq(some.map(fn(v: i32) i32 { v * 2 }).unwrap_or(0), 42, "Some maps through f")
    assert_true(none.map(fn(v: i32) i32 { v * 2 }).is_none(), "None maps to None")
}

test "flat_map chains a fallible step without nesting" {
    let some: Option(i32) = Some(4)
    let none: Option(i32) = null
    // `f` itself returns an Option; the result stays one level deep.
    assert_eq(some.flat_map(fn(v: i32) Option(i32) { halve(v) }).unwrap_or(0), 2, "Some chains through f")
    assert_true(some.flat_map(fn(v: i32) Option(i32) { halve(v + 1) }).is_none(), "an f returning None collapses")
    assert_true(none.flat_map(fn(v: i32) Option(i32) { halve(v) }).is_none(), "None short-circuits, f never runs")
}

fn halve(v: i32) Option(i32) {
    if v % 2 == 0 { return Some(v / 2) }
    return null
}
