//! TEST: glob_basic
//! EXIT: 0
//! STDOUT: ok

// Exercise the glob matcher directly (no filesystem) to avoid fragility
// from depending on fixture contents.

import std.io.fs

pub fn main() i32 {
    // `*` matches within a segment
    if !match_glob("*.f", "foo.f") { println("1"); return 1 }
    if match_glob("*.f", "foo/bar.f") { println("2"); return 2 }  // no cross-dir
    if match_glob("*.f", "foo.txt") { println("3"); return 3 }
    if !match_glob("foo*", "foobar") { println("4"); return 4 }

    // `**` crosses segments, including zero segments
    if !match_glob("**", "foo") { println("5"); return 5 }
    if !match_glob("**/*.f", "a/b/c.f") { println("6"); return 6 }
    if !match_glob("**/*.f", "c.f") { println("7"); return 7 }     // ** = zero segs
    if !match_glob("src/**/*.f", "src/a/b/x.f") { println("8"); return 8 }
    if !match_glob("src/**/*.f", "src/x.f") { println("9"); return 9 }
    if match_glob("src/**/*.f", "other/x.f") { println("10"); return 10 }

    // `?` is a single non-separator byte
    if !match_glob("?bc", "abc") { println("11"); return 11 }
    if match_glob("?bc", "abcd") { println("12"); return 12 }
    if match_glob("a?c", "a/c") { println("13"); return 13 }

    // Literal-only patterns
    if !match_glob("foo", "foo") { println("14"); return 14 }
    if match_glob("foo", "bar") { println("15"); return 15 }

    // Empty path + empty pattern
    if !match_glob("", "") { println("16"); return 16 }

    println("ok")
    return 0
}
