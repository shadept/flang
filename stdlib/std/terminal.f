// Terminal management: ANSI escape codes, cursor control, colors, styles.
//
// All output functions write escape sequences to a Writer, so they work with
// any output target (stdout, file, StringBuilder, BufferedWriter, etc.).

import std.io.writer
import std.string_builder
import std.test

// =============================================================================
// Terminal Size
// =============================================================================

pub type TerminalSize = struct {
    rows: u16
    cols: u16
}

type Winsize = struct {
    ws_row: u16
    ws_col: u16
    ws_xpixel: u16
    ws_ypixel: u16
}

// macOS value; TODO: linux uses 0x5413
const TIOCGWINSZ: u64 = 0x40087468

#foreign fn ioctl(fd: i32, request: u64, argp: &u8) i32

// Query the terminal dimensions. Falls back to 80x24 on failure.
pub fn get_terminal_size() TerminalSize {
    let ws = Winsize { ws_row = 0, ws_col = 0, ws_xpixel = 0, ws_ypixel = 0 }
    const ret = ioctl(1, TIOCGWINSZ, &ws as &u8)
    if ret == -1 {
        return TerminalSize { rows = 24, cols = 80 }
    }
    return TerminalSize { rows = ws.ws_row, cols = ws.ws_col }
}

// =============================================================================
// Cursor Movement
// =============================================================================

// Move cursor to absolute position (1-based).  ESC [ row ; col H
pub fn move_to(w: Writer, row: u32, col: u32) {
    write_csi(w)
    write_uint(w, row)
    w.write_byte(';')
    write_uint(w, col)
    w.write_byte('H')
}

// Move cursor up by n lines.  ESC [ n A
pub fn move_up(w: Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write_byte('A')
}

// Move cursor down by n lines.  ESC [ n B
pub fn move_down(w: Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write_byte('B')
}

// Move cursor right by n columns.  ESC [ n C
pub fn move_right(w: Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write_byte('C')
}

// Move cursor left by n columns.  ESC [ n D
pub fn move_left(w: Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write_byte('D')
}

// Save cursor position.  ESC [ s
pub fn save_cursor(w: Writer) {
    write_csi(w)
    w.write_byte('s')
}

// Restore cursor position.  ESC [ u
pub fn restore_cursor(w: Writer) {
    write_csi(w)
    w.write_byte('u')
}

// Hide cursor.  ESC [ ? 25 l
pub fn hide_cursor(w: Writer) {
    write_csi(w)
    w.write_str("?25l")
}

// Show cursor.  ESC [ ? 25 h
pub fn show_cursor(w: Writer) {
    write_csi(w)
    w.write_str("?25h")
}

// =============================================================================
// Colors
// =============================================================================

pub type Color = enum {
    Black = 0
    Red = 1
    Green = 2
    Yellow = 3
    Blue = 4
    Magenta = 5
    Cyan = 6
    White = 7
    Default = 9
}

fn write_color_code(w: Writer, color: Color) {
    const code: u32 = color match {
        Black => 0,
        Red => 1,
        Green => 2,
        Yellow => 3,
        Blue => 4,
        Magenta => 5,
        Cyan => 6,
        White => 7,
        Default => 9,
    }
    write_uint(w, code)
}

// Set foreground color.  ESC [ 3{c} m
pub fn set_fg(w: Writer, color: Color) {
    write_csi(w)
    w.write_byte('3')
    write_color_code(w, color)
    w.write_byte('m')
}

// Set background color.  ESC [ 4{c} m
pub fn set_bg(w: Writer, color: Color) {
    write_csi(w)
    w.write_byte('4')
    write_color_code(w, color)
    w.write_byte('m')
}

// Set bright foreground color.  ESC [ 9{c} m
pub fn set_bright_fg(w: Writer, color: Color) {
    write_csi(w)
    w.write_byte('9')
    write_color_code(w, color)
    w.write_byte('m')
}

// Set bright background color.  ESC [ 10{c} m
pub fn set_bright_bg(w: Writer, color: Color) {
    write_csi(w)
    write_uint(w, 10)
    write_color_code(w, color)
    w.write_byte('m')
}

// =============================================================================
// Styles
// =============================================================================

pub type Style = enum {
    Bold = 1
    Dim = 2
    Italic = 3
    Underline = 4
    Blink = 5
    Reverse = 7
    Hidden = 8
    Strikethrough = 9
}

// Enable a text style.  ESC [ {code} m
pub fn set_style(w: Writer, style: Style) {
    const code: u32 = style match {
        Bold => 1,
        Dim => 2,
        Italic => 3,
        Underline => 4,
        Blink => 5,
        Reverse => 7,
        Hidden => 8,
        Strikethrough => 9,
    }
    write_csi(w)
    write_uint(w, code)
    w.write_byte('m')
}

// Reset all attributes (color + style).  ESC [ 0 m
pub fn reset(w: Writer) {
    write_csi(w)
    w.write_byte('0')
    w.write_byte('m')
}

// =============================================================================
// Screen Control
// =============================================================================

// Clear entire screen.  ESC [ 2 J
pub fn clear_screen(w: Writer) {
    write_csi(w)
    w.write_str("2J")
}

// Clear from cursor to end of screen.  ESC [ 0 J
pub fn clear_below(w: Writer) {
    write_csi(w)
    w.write_str("0J")
}

// Clear from cursor to beginning of screen.  ESC [ 1 J
pub fn clear_above(w: Writer) {
    write_csi(w)
    w.write_str("1J")
}

// Clear entire line.  ESC [ 2 K
pub fn clear_line(w: Writer) {
    write_csi(w)
    w.write_str("2K")
}

// Clear from cursor to end of line.  ESC [ 0 K
pub fn clear_line_right(w: Writer) {
    write_csi(w)
    w.write_str("0K")
}

// Clear from cursor to beginning of line.  ESC [ 1 K
pub fn clear_line_left(w: Writer) {
    write_csi(w)
    w.write_str("1K")
}

// =============================================================================
// Constants
// =============================================================================

const ESC: u8 = 27

// =============================================================================
// Internal helpers
// =============================================================================

// Write CSI (Control Sequence Introducer): ESC [
fn write_csi(w: Writer) {
    w.write_byte(ESC)
    w.write_byte('[')
}

// =============================================================================
// Tests
// =============================================================================

test "escape codes" {
    let sb = string_builder(64)
    let w = sb.writer()

    // move_to(3, 5) -> ESC [ 3 ; 5 H
    move_to(w, 3, 5)
    let view = sb.as_view()
    assert_eq(view.len as i32, 6, "move_to len")
    assert_eq(view[0], 27u8, "ESC")
    assert_eq(view[1], '[', "[")
    assert_eq(view[2], '3', "3")
    assert_eq(view[3], ';', ";")
    assert_eq(view[4], '5', "5")
    assert_eq(view[5], 'H', "H")
    sb.clear()

    // reset -> ESC [ 0 m
    reset(w)
    let view2 = sb.as_view()
    assert_eq(view2.len as i32, 4, "reset len")
    assert_eq(view2[0], 27u8, "ESC")
    assert_eq(view2[1], '[', "[")
    assert_eq(view2[2], '0', "0")
    assert_eq(view2[3], 'm', "m")
    sb.clear()

    // move_up(1) -> ESC [ 1 A
    move_up(w, 1)
    let view3 = sb.as_view()
    assert_eq(view3.len as i32, 4, "move_up len")
    assert_eq(view3[2], '1', "1")
    assert_eq(view3[3], 'A', "A")
    sb.clear()

    // clear_screen -> ESC [ 2 J
    clear_screen(w)
    let view4 = sb.as_view()
    assert_eq(view4.len as i32, 4, "clear_screen len")
    assert_eq(view4[2], '2', "2")
    assert_eq(view4[3], 'J', "J")

    sb.deinit()
}

test "colors" {
    let sb = string_builder(64)
    let w = sb.writer()

    // set_fg(Color.Red) -> ESC [ 3 1 m
    set_fg(w, Color.Red)
    let view = sb.as_view()
    assert_eq(view.len as i32, 5, "set_fg len")
    assert_eq(view[0], 27u8, "ESC")
    assert_eq(view[1], '[', "[")
    assert_eq(view[2], '3', "3")
    assert_eq(view[3], '1', "1")
    assert_eq(view[4], 'm', "m")
    sb.clear()

    // set_bg(Color.Blue) -> ESC [ 4 4 m
    set_bg(w, Color.Blue)
    let view2 = sb.as_view()
    assert_eq(view2.len as i32, 5, "set_bg len")
    assert_eq(view2[2], '4', "4")
    assert_eq(view2[3], '4', "4")
    assert_eq(view2[4], 'm', "m")
    sb.clear()

    // set_style(Style.Bold) -> ESC [ 1 m
    set_style(w, Style.Bold)
    let view3 = sb.as_view()
    assert_eq(view3.len as i32, 4, "set_style len")
    assert_eq(view3[2], '1', "1")
    assert_eq(view3[3], 'm', "m")
    sb.clear()

    // set_fg(Color.Default) -> ESC [ 3 9 m
    set_fg(w, Color.Default)
    let view4 = sb.as_view()
    assert_eq(view4.len as i32, 5, "set_fg default len")
    assert_eq(view4[2], '3', "3")
    assert_eq(view4[3], '9', "9")

    sb.deinit()
}
