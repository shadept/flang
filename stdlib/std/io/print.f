// `print` and `println`: a value's text to stdout, through its `format`, so anything formattable
// prints. Code whose output should be testable or redirectable formats to a `Writer` instead.
//
// The template forms are `format_to` (`std.format`) aimed at stdout: `println("{} and {}", a, b)`,
// holes in the language's own interpolation grammar.

import std.format
import std.io.file
import std.io.writer
import std.option
import std.string

// Writes `value`'s text to stdout. One print is one write: the text collects in a stack buffer and
// goes out when the call returns, so a value formatted piecewise costs a single syscall. Nothing is
// buffered across calls, so output never trails output from anything else.
pub fn print(value: $T) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    value.format(out.writer(), "")
    out.flush()
}

// Writes the referenced value's text to stdout.
pub fn print(value: &$T) {
    print(value.*)
}

// Writes the string and frees it, so `print($"...")` needs no temporary.
pub fn print(value: OwnedString) {
    defer value.deinit()
    print(value.as_view())
}

// Writes the payload's text, or `null`.
pub fn print(value: Option($T)) {
    value match {
        Some(v) => { print(v) }
        None => { print("null") }
    }
}

// Writes `value`'s text and a newline to stdout: two writes.
pub fn println(value: $T) {
    print(value)
    print("\n")
}

// Writes the referenced value's text and a newline.
pub fn println(value: &$T) {
    println(value.*)
}

// Writes the string and a newline, then frees it.
pub fn println(value: OwnedString) {
    defer value.deinit()
    println(value.as_view())
}

// Writes the payload's text, or `null`, and a newline.
pub fn println(value: Option($T)) {
    print(value)
    print("\n")
}

// Writes `template` with its holes filled from the arguments (`format_to`).
pub fn print(template: String, a: $A) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a)
    out.flush()
}

// Writes `template` with its holes filled from the arguments (`format_to`).
pub fn print(template: String, a: $A, b: $B) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a, b)
    out.flush()
}

// Writes `template` with its holes filled from the arguments (`format_to`).
pub fn print(template: String, a: $A, b: $B, c: $C) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a, b, c)
    out.flush()
}

// Writes `template` with its holes filled from the arguments, and a newline.
pub fn println(template: String, a: $A) {
    print(template, a)
    print("\n")
}

// Writes `template` with its holes filled from the arguments, and a newline.
pub fn println(template: String, a: $A, b: $B) {
    print(template, a, b)
    print("\n")
}

// Writes `template` with its holes filled from the arguments, and a newline.
pub fn println(template: String, a: $A, b: $B, c: $C) {
    print(template, a, b, c)
    print("\n")
}
