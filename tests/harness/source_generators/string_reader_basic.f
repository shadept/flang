//! TEST: string_reader_basic
//! EXIT: 0

// `String` readers reach an OwnedString's view through op_deref.

import std.allocator
import std.option
import std.string

pub fn main() i32 {
    // An owned copy of a string literal
    const sv: String = "  hello world  "
    const owned = from_view(sv)
    defer owned.deinit()
    const text = owned.view()

    // find
    const idx: usize = text.find("world") ?? 999
    if idx != 8 {
        return 2
    }

    // find - not found
    const miss = text.find("xyz")
    if miss.is_some() {
        return 3
    }

    // rfind
    const sv2: String = "abcabc"
    const owned2 = from_view(sv2)
    defer owned2.deinit()
    const ri: usize = owned2.view().rfind("abc") ?? 999
    if ri != 3 {
        return 5
    }

    // contains
    if !text.contains("hello") {
        return 6
    }
    if text.contains("xyz") {
        return 7
    }

    // starts_with
    if !text.starts_with("  hello") {
        return 8
    }
    if text.starts_with("hello") {
        return 9
    }

    // ends_with
    if !text.ends_with("world  ") {
        return 10
    }
    if text.ends_with("world") {
        return 11
    }

    // trim
    const trimmed = text.trim()
    if trimmed.len != 11 {
        return 12
    }
    if !trimmed.starts_with("hello") {
        return 13
    }
    if !trimmed.ends_with("world") {
        return 14
    }

    // trim_start
    const ts = text.trim_start()
    if ts.len != 13 {
        return 15
    }
    if !ts.starts_with("hello") {
        return 16
    }

    // trim_end
    const te = text.trim_end()
    if te.len != 13 {
        return 17
    }
    if !te.ends_with("world") {
        return 18
    }

    return 0
}
