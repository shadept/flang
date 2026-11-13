//! TEST: labeled_context
//! STDOUT: in 4
//! STDOUT: out 0
//! EXIT: 0

// A labeled jump passes through `context(...) { }`, running each defer under the context current
// where it was written.
import std.io.print
import std.string_builder

context level: i32 = 0

fn note(tag: String) {
    println($"{tag} {context.level}")
}

pub fn main() i32 {
    let seen: i32 = 0
    outer: loop {
        defer note("out")
        context(level = 4i32) {
            defer note("in")
            for _i in 0..3 as i32 {
                seen = context.level
                break outer
            }
        }
    }
    if seen != 4 {
        return 1
    }
    if context.level != 0 {
        return 2
    }
    return 0
}
