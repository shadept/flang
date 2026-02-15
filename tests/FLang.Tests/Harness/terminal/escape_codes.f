//! TEST: terminal_escape_codes
//! EXIT: 0

// Verify ANSI escape sequences by writing to a StringBuilder-backed Writer
// and checking the resulting bytes.

import std.io.writer
import std.string_builder
import std.terminal

pub fn main() i32 {
    let sb = string_builder_with_capacity(64)
    let w = sb.writer()

    // Test move_to(3, 5) -> ESC [ 3 ; 5 H
    move_to(&w, 3, 5)
    w.flush()
    let view = sb.as_view()

    // ESC=27 [=91 3=51 ;=59 5=53 H=72
    if view.len != 6 { return 1 }
    if view[0] != 27  { return 2 }
    if view[1] != 91  { return 3 }
    if view[2] != 51  { return 4 }
    if view[3] != 59  { return 5 }
    if view[4] != 53  { return 6 }
    if view[5] != 72  { return 7 }

    sb.clear()

    // Test reset -> ESC [ 0 m
    reset(&w)
    w.flush()
    let view2 = sb.as_view()
    if view2.len != 4 { return 10 }
    if view2[0] != 27  { return 11 }
    if view2[1] != 91  { return 12 }
    if view2[2] != 48  { return 13 }  // '0'
    if view2[3] != 109 { return 14 }  // 'm'

    sb.clear()

    // Test move_up(1) -> ESC [ 1 A
    move_up(&w, 1)
    w.flush()
    let view3 = sb.as_view()
    if view3.len != 4 { return 20 }
    if view3[0] != 27 { return 21 }
    if view3[1] != 91 { return 22 }
    if view3[2] != 49 { return 23 }  // '1'
    if view3[3] != 65 { return 24 }  // 'A'

    sb.clear()

    // Test clear_screen -> ESC [ 2 J
    clear_screen(&w)
    w.flush()
    let view4 = sb.as_view()
    if view4.len != 4 { return 30 }
    if view4[0] != 27 { return 31 }
    if view4[1] != 91 { return 32 }
    if view4[2] != 50 { return 33 }  // '2'
    if view4[3] != 74 { return 34 }  // 'J'

    sb.deinit()
    return 0
}
