//! TEST: string_helpers
//! EXIT: 0

import std.list
import std.option
import std.string
import std.string_builder

pub fn main() i32 {
    // ------- char-overload find / rfind / count -------
    const f1 = find("hello/world/foo", '/')
    if f1.unwrap() != 5 { return 1 }
    const f2 = find("hello", 'x')
    if f2.is_some() { return 2 }
    const f3 = rfind("hello/world/foo", '/')
    if f3.unwrap() != 11 { return 3 }
    if count("a.b.c.d", '.') != 3 { return 4 }
    if count("abc", '.') != 0 { return 5 }

    // count with String needle
    if count("abxabxab", "ab") != 3 { return 6 }
    if count("aaaa", "aa") != 2 { return 7 }  // non-overlapping

    // multi-byte char find — 'é' is 0xC3 0xA9 in UTF-8
    const f4 = find("café-bar", 'é')
    if f4.unwrap() != 3 { return 8 }

    // ------- strip_prefix / strip_suffix -------
    const sp1 = strip_prefix("core.option", "core.")
    if sp1.unwrap() != "option" { return 10 }
    const sp2 = strip_prefix("std.io", "core.")
    if sp2.is_some() { return 11 }
    const ss1 = strip_suffix("main.f", ".f")
    if ss1.unwrap() != "main" { return 12 }
    const ss2 = strip_suffix("main.c", ".f")
    if ss2.is_some() { return 13 }

    // ------- split_at -------
    const sa = split_at("src/foo.f", 3)
    if sa.0 != "src" { return 20 }
    if sa.1 != "/foo.f" { return 21 }
    const sa2 = split_at("abc", 100)
    if sa2.0 != "abc" { return 22 }
    if sa2.1 != "" { return 23 }

    // ------- is_ascii / eq_ignore_ascii_case -------
    if !is_ascii("hello-world") { return 30 }
    if is_ascii("café") { return 31 }
    if !eq_ignore_ascii_case("Hello", "HELLO") { return 32 }
    if eq_ignore_ascii_case("hello", "world") { return 33 }
    if !eq_ignore_ascii_case("", "") { return 34 }

    // ------- lines -------
    let count_lines: i32 = 0
    let combined = string_builder()
    defer combined.deinit()
    const text = "alpha\nbeta\r\ngamma"
    for line in text.lines() {
        if count_lines > 0 { combined.append("|") }
        combined.append(line)
        count_lines = count_lines + 1
    }
    if count_lines != 3 { return 40 }
    if combined.as_view() != "alpha|beta|gamma" { return 41 }

    // Trailing newline: yields each line, no empty tail.
    let count2: i32 = 0
    for _i in "a\nb\n".lines() {
        count2 = count2 + 1
    }
    if count2 != 2 { return 42 }

    // ------- split (String delimiter) -------
    let parts = split("a::b::c", "::")
    defer parts.deinit()
    if parts.len != 3 { return 50 }
    if parts[0] != "a" { return 51 }
    if parts[1] != "b" { return 52 }
    if parts[2] != "c" { return 53 }

    let parts2 = split("a::b::c", "::", 1)
    defer parts2.deinit()
    if parts2.len != 2 { return 54 }
    if parts2[1] != "b::c" { return 55 }

    // byte-split still works
    let parts3 = split("a,b,c", ',')
    defer parts3.deinit()
    if parts3.len != 3 { return 56 }
    if parts3[2] != "c" { return 57 }

    // ------- StringBuilder transformers -------
    let sb = string_builder()
    defer sb.deinit()

    sb.append_replaced("hello world", "world", "FLang")
    if sb.as_view() != "hello FLang" { return 60 }
    sb.clear()

    sb.append_replaced("a.b.c.d", ".", "-")
    if sb.as_view() != "a-b-c-d" { return 61 }
    sb.clear()

    let arr = ["red", "green", "blue"]
    sb.append_joined(arr, ", ")
    if sb.as_view() != "red, green, blue" { return 62 }
    sb.clear()

    sb.append_repeated("ab", 3)
    if sb.as_view() != "ababab" { return 63 }
    sb.clear()

    sb.append_reversed("hello")
    if sb.as_view() != "olleh" { return 64 }
    sb.clear()

    sb.append_padded("42", 5, '>', ' ')
    if sb.as_view() != "   42" { return 65 }
    sb.clear()

    sb.append_padded("42", 5, '<', '0')
    if sb.as_view() != "42000" { return 66 }
    sb.clear()

    sb.append_padded("hi", 6, '^', '-')
    if sb.as_view() != "--hi--" { return 67 }
    sb.clear()

    sb.append_padded("long", 2, '>', ' ')
    if sb.as_view() != "long" { return 68 }  // no truncation
    sb.clear()

    sb.append_lower_ascii("Hello World 123")
    if sb.as_view() != "hello world 123" { return 70 }
    sb.clear()

    sb.append_upper_ascii("Hello World 123")
    if sb.as_view() != "HELLO WORLD 123" { return 71 }
    sb.clear()

    return 0
}
