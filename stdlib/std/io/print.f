// `print` and `println` - the convenience end of output. Each writes a value's text to stdout
// through its `format`, so anything formattable prints. Code that wants its output testable or
// redirectable formats to a `Writer` instead; these are for the quick case.
//
// The template forms are `format_to` (`std.format`) aimed at stdout: `println("{} and {}", a, b)`,
// holes in the language's own interpolation grammar.

import std.format
import std.io.file
import std.io.writer
import std.option
import std.string

// One print is one write: the value's text collects in a stack buffer over the `stdout` file and
// goes out when the print returns, so a struct formatted piecewise still costs a single syscall.
// Nothing is buffered across calls - there is no global state to flush at exit, and output from
// `print` never trails output from anything else. `println` is a print and a newline, two writes;
// line-flush semantics are still open.
pub fn print(value: $T) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    value.format(out.writer(), "")
    out.flush()
}

pub fn print(value: &$T) {
    print(value.*)
}

// Takes ownership and frees, so `print($"...")` needs no temporary.
pub fn print(value: OwnedString) {
    defer value.deinit()
    print(value.as_view())
}

pub fn print(value: Option($T)) {
    value match {
        Some(v) => { print(v) }
        None => { print("null") }
    }
}

pub fn println(value: $T) {
    print(value)
    print("\n")
}

pub fn println(value: &$T) {
    println(value.*)
}

pub fn println(value: OwnedString) {
    defer value.deinit()
    println(value.as_view())
}

pub fn println(value: Option($T)) {
    print(value)
    print("\n")
}

pub fn print(template: String, a: $A) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a)
    out.flush()
}

pub fn print(template: String, a: $A, b: $B) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a, b)
    out.flush()
}

pub fn print(template: String, a: $A, b: $B, c: $C) {
    let storage = [0u8; 512]
    let out = buffered_writer(stdout.writer(), storage)
    format_to(out.writer(), template, a, b, c)
    out.flush()
}

pub fn println(template: String, a: $A) {
    print(template, a)
    print("\n")
}

pub fn println(template: String, a: $A, b: $B) {
    print(template, a, b)
    print("\n")
}

pub fn println(template: String, a: $A, b: $B, c: $C) {
    print(template, a, b, c)
    print("\n")
}
