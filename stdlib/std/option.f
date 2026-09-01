// Standard library support for the Option type.
// Along with re-exporting core.option.Option, the standard library offers functions to interact
// with the Option type.

import core.option
import std.test

// Deinit the payload (if any) and reset to `None`. Lets options participate in container cascades
// (`List(Option(T)).deinit` reaches the payloads) and makes `opt.deinit()` the one-liner for owned
// optional fields. Idempotent: the second call sees `None`.
pub fn deinit(self: &Option($T)) {
    self.* match {
        Some(v) => { v.deinit() }
        None => {}
    }
    self.* = None
}

// Read-only, so the receiver is a reference: a by-value receiver of a non-copyable type has no
// receiver form at all (RFC-028), and `opt.is_some()` has to keep working for every payload.
pub fn is_some(self: &Option($T)) bool {
    return self.* match {
        Some(_) => true
        None => false
    }
}

pub fn is_none(self: &Option($T)) bool {
    return self.* match {
        Some(_) => false
        None => true
    }
}

pub fn expect(self: Option($T), msg: String) T {
    return self match {
        Some(v) => v
        None => panic(msg)
    }
}

// Unwrap the Some payload, panicking on None. Use `unwrap_or` / `match` when None is reachable;
// reserve `unwrap` for invariants you've already checked (e.g. inside an `if x.is_some()` branch).
pub fn unwrap(self: Option($T)) T {
    return self.expect("called `unwrap` on a `None` value")
}

// The payload, or `fallback`. The argument is evaluated whether or not the option is empty;
// `unwrap_or_else` defers it to the empty case.
pub fn unwrap_or(self: Option($T), fallback: T) T {
    return self match {
        Some(v) => v
        None => fallback
    }
}

// The payload, or the result of calling `make`. `make` runs only when the option is empty.
pub fn unwrap_or_else(self: Option($T), make: $F) T {
    return self match {
        Some(v) => v
        None => make()
    }
}

// Apply `f` to a present value, leaving `None` untouched. Use it to transform what an optional
// holds without unwrapping and re-wrapping; `f` never runs on `None`. When `f` itself returns an
// `Option`, use `flat_map` so the result does not nest.
pub fn map(self: Option($T), f: $F) Option($U) {
    return self match {
        Some(v) => Some(f(v))
        None => None
    }
}

// `map` for a function that itself yields an `Option`, flattening the result. Chains a fallible
// step onto a fallible one: passing such a function to `map` would give `Option(Option(U))`,
// whereas this stays one level deep. `None` short-circuits and `f` never runs.
pub fn flat_map(self: Option($T), f: $F) Option($U) {
    return self match {
        Some(v) => f(v)
        None => None
    }
}

// Keep a present value only when it satisfies `pred`, otherwise `None`. The narrowing counterpart
// of `map`: `map` changes what the optional holds, `filter` changes whether it holds anything.
// `pred` never runs on `None`.
//
// Chains where each step is a separate reason to give up read as one expression rather than a stack
// of early returns.
pub fn filter(self: Option($T), pred: $F) Option(T) {
    return self match {
        Some(v) => if pred(v) { self } else { None }
        None => None
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

// Null-coalescing operator: Option(T) ?? Option(T) -> Option(T) Returns the first option if it has
// a value, otherwise returns the second.
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
    assert_eq(some.flat_map(fn(v: i32) Option(i32) { halve(v) }).unwrap_or(0), 2,
        "Some chains through f")
    assert_true(some.flat_map(fn(v: i32) Option(i32) { halve(v + 1) }).is_none(),
        "an f returning None collapses")
    assert_true(none.flat_map(fn(v: i32) Option(i32) { halve(v) }).is_none(),
        "None short-circuits, f never runs")
}

fn halve(v: i32) Option(i32) {
    if v % 2 == 0 {
        return Some(v / 2)
    }
    return null
}

test "filter keeps a value that passes and drops one that fails" {
    let kept: Option(i32) = Some(4)
    let dropped: Option(i32) = Some(3)
    assert_eq(kept.filter(fn(v: i32) bool { v % 2 == 0 }).unwrap_or(-1), 4,
        "an even value survives")
    assert_eq(dropped.filter(fn(v: i32) bool { v % 2 == 0 }).unwrap_or(-1), -1,
        "an odd value is filtered out")
}

test "filter never runs its predicate on None" {
    let none: Option(i32) = null
    assert_true(none.filter(fn(v: i32) bool { true }).is_none(),
        "None stays None, predicate untouched")
}
