//! TEST: terminal_colors
//! EXIT: 0

// Verify color and style escape sequences.

import std.io.writer
import std.string_builder
import std.terminal

pub fn main() i32 {
    let sb = string_builder(64)
    let w = sb.writer()

    // Test set_fg(Color.Red) -> ESC [ 3 1 m
    set_fg(&w, Color.Red)
    w.flush()
    let view = sb.as_view()

    // ESC=27 [=91 3=51 1=49 m=109
    if view.len != 5 { return 1 }
    if view[0] != 27  { return 2 }
    if view[1] != 91  { return 3 }
    if view[2] != 51  { return 4 }  // '3'
    if view[3] != 49  { return 5 }  // '1'
    if view[4] != 109 { return 6 }  // 'm'

    sb.clear()

    // Test set_bg(Color.Blue) -> ESC [ 4 4 m
    set_bg(&w, Color.Blue)
    w.flush()
    let view2 = sb.as_view()
    if view2.len != 5 { return 10 }
    if view2[0] != 27  { return 11 }
    if view2[2] != 52  { return 12 }  // '4'
    if view2[3] != 52  { return 13 }  // '4'
    if view2[4] != 109 { return 14 }  // 'm'

    sb.clear()

    // Test set_style(Style.Bold) -> ESC [ 1 m
    set_style(&w, Style.Bold)
    w.flush()
    let view3 = sb.as_view()
    if view3.len != 4 { return 20 }
    if view3[0] != 27  { return 21 }
    if view3[1] != 91  { return 22 }
    if view3[2] != 49  { return 23 }  // '1'
    if view3[3] != 109 { return 24 }  // 'm'

    sb.clear()

    // Test set_fg(Color.Default) -> ESC [ 3 9 m
    set_fg(&w, Color.Default)
    w.flush()
    let view4 = sb.as_view()
    if view4.len != 5 { return 30 }
    if view4[2] != 51  { return 31 }  // '3'
    if view4[3] != 57  { return 32 }  // '9'

    sb.deinit()
    return 0
}
