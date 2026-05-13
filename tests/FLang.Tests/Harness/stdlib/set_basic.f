//! TEST: set_basic
//! EXIT: 0

import std.option
import std.set
import std.string

pub fn main() i32 {
    let s: Set(OwnedString) = set()
    defer s.deinit()

    if !s.is_empty() { return 1 }
    if s.contains("hello") { return 2 }

    s.add("hello")
    s.add("world")
    s.add("hello")           // duplicate — no-op
    if s.len() != 2 { return 3 }
    if !s.contains("hello") { return 4 }
    if !s.contains("world") { return 5 }
    if s.contains("missing") { return 6 }

    // remove returns whether the element was present.
    if !s.remove("hello") { return 7 }
    if s.remove("hello") { return 8 }
    if s.contains("hello") { return 9 }
    if s.len() != 1 { return 10 }

    // iter — verify exactly the remaining element is yielded.
    let it = s.iter()
    let first = it.next()
    if first.is_none() { return 11 }
    if first.unwrap().as_view() != "world" { return 12 }
    if it.next().is_some() { return 13 }

    s.clear()
    if !s.is_empty() { return 14 }

    return 0
}
