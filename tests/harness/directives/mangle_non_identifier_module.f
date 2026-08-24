//! TEST: mangle_non_identifier_module
//! STDOUT: PASS

// Symbols must be valid C identifiers even when the module path is not one
// (docs/spec.md 7.1.1, property 4). A module path is built from the project
// name and file path, so it can carry any character a manifest allows -
// `name = "chess-fen"` used to emit `chess-fen_main_f`, which C parses as a
// subtraction and rejects.
//
// This file only pins the escape's INJECTIVITY, which property 1 needs: an
// underscore and the escape prefix it shares must stay distinguishable, so
// these four names cannot collapse onto one symbol. The path-derived half is
// covered by `examples/chess-fen` building.

fn f_x() i32 { return 1 }
fn f_0x() i32 { return 2 }
fn fx() i32 { return 4 }
fn f__x() i32 { return 8 }

pub fn main() i32 {
    const total = f_x() + f_0x() + fx() + f__x()
    if total != 15 {
        println("FAIL: names collided, got")
        println(total)
        return 1
    }
    println("PASS")
    return 0
}
