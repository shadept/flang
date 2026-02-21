// Terminal management: ANSI escape codes, cursor control, colors, styles.
//
// All output functions write escape sequences to a BufferedWriter, so they work
// with any output target (stdout, file, StringBuilder, etc.).

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
pub fn move_to(w: &BufferedWriter, row: u32, col: u32) {
    write_csi(w)
    write_uint(w, row)
    w.write(b';')
    write_uint(w, col)
    w.write(b'H')
}

// Move cursor up by n lines.  ESC [ n A
pub fn move_up(w: &BufferedWriter, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'A')
}

// Move cursor down by n lines.  ESC [ n B
pub fn move_down(w: &BufferedWriter, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'B')
}

// Move cursor right by n columns.  ESC [ n C
pub fn move_right(w: &BufferedWriter, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'C')
}

// Move cursor left by n columns.  ESC [ n D
pub fn move_left(w: &BufferedWriter, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'D')
}

// Save cursor position.  ESC [ s
pub fn save_cursor(w: &BufferedWriter) {
    write_csi(w)
    w.write(b's')
}

// Restore cursor position.  ESC [ u
pub fn restore_cursor(w: &BufferedWriter) {
    write_csi(w)
    w.write(b'u')
}

// Hide cursor.  ESC [ ? 25 l
pub fn hide_cursor(w: &BufferedWriter) {
    write_csi(w)
    w.write("?25l")
}

// Show cursor.  ESC [ ? 25 h
pub fn show_cursor(w: &BufferedWriter) {
    write_csi(w)
    w.write("?25h")
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

fn write_color_code(w: &BufferedWriter, color: Color) {
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
pub fn set_fg(w: &BufferedWriter, color: Color) {
    write_csi(w)
    w.write(b'3')
    write_color_code(w, color)
    w.write(b'm')
}

// Set background color.  ESC [ 4{c} m
pub fn set_bg(w: &BufferedWriter, color: Color) {
    write_csi(w)
    w.write(b'4')
    write_color_code(w, color)
    w.write(b'm')
}

// Set bright foreground color.  ESC [ 9{c} m
pub fn set_bright_fg(w: &BufferedWriter, color: Color) {
    write_csi(w)
    w.write(b'9')
    write_color_code(w, color)
    w.write(b'm')
}

// Set bright background color.  ESC [ 10{c} m
pub fn set_bright_bg(w: &BufferedWriter, color: Color) {
    write_csi(w)
    write_uint(w, 10)
    write_color_code(w, color)
    w.write(b'm')
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
pub fn set_style(w: &BufferedWriter, style: Style) {
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
    w.write(b'm')
}

// Reset all attributes (color + style).  ESC [ 0 m
pub fn reset(w: &BufferedWriter) {
    write_csi(w)
    w.write(b'0')
    w.write(b'm')
}

// =============================================================================
// Screen Control
// =============================================================================

// Clear entire screen.  ESC [ 2 J
pub fn clear_screen(w: &BufferedWriter) {
    write_csi(w)
    w.write("2J")
}

// Clear from cursor to end of screen.  ESC [ 0 J
pub fn clear_below(w: &BufferedWriter) {
    write_csi(w)
    w.write("0J")
}

// Clear from cursor to beginning of screen.  ESC [ 1 J
pub fn clear_above(w: &BufferedWriter) {
    write_csi(w)
    w.write("1J")
}

// Clear entire line.  ESC [ 2 K
pub fn clear_line(w: &BufferedWriter) {
    write_csi(w)
    w.write("2K")
}

// Clear from cursor to end of line.  ESC [ 0 K
pub fn clear_line_right(w: &BufferedWriter) {
    write_csi(w)
    w.write("0K")
}

// Clear from cursor to beginning of line.  ESC [ 1 K
pub fn clear_line_left(w: &BufferedWriter) {
    write_csi(w)
    w.write("1K")
}

// =============================================================================
// Constants
// =============================================================================

const ESC: u8 = 27

// =============================================================================
// Internal helpers
// =============================================================================

// Write CSI (Control Sequence Introducer): ESC [
fn write_csi(w: &BufferedWriter) {
    w.write(ESC)
    w.write(b'[')
}

// Write an unsigned integer as decimal digits to a BufferedWriter.
fn write_uint(w: &BufferedWriter, value: u32) {
    if value == 0 {
        w.write(b'0')
        return
    }

    let buf = [0u8; 10]
    let pos: usize = 10
    let v = value

    loop {
        if v == 0 { break }
        pos = pos - 1
        buf[pos] = b'0' + (v % 10) as u8
        v = v / 10
    }

    w.write(buf[pos..])
}

// =============================================================================
// Tests
// =============================================================================

test "escape codes" {
    let sb = string_builder(64)
    let w = sb.buffered_writer()

    // move_to(3, 5) -> ESC [ 3 ; 5 H
    move_to(&w, 3, 5)
    w.flush()
    let view = sb.as_view()
    assert_eq(view.len as i32, 6, "move_to len")
    assert_eq(view[0], 27u8, "ESC")
    assert_eq(view[1], 91u8, "[")
    assert_eq(view[2], 51u8, "3")
    assert_eq(view[3], 59u8, ";")
    assert_eq(view[4], 53u8, "5")
    assert_eq(view[5], 72u8, "H")
    sb.clear()

    // reset -> ESC [ 0 m
    reset(&w)
    w.flush()
    let view2 = sb.as_view()
    assert_eq(view2.len as i32, 4, "reset len")
    assert_eq(view2[0], 27u8, "ESC")
    assert_eq(view2[1], 91u8, "[")
    assert_eq(view2[2], 48u8, "0")
    assert_eq(view2[3], 109u8, "m")
    sb.clear()

    // move_up(1) -> ESC [ 1 A
    move_up(&w, 1)
    w.flush()
    let view3 = sb.as_view()
    assert_eq(view3.len as i32, 4, "move_up len")
    assert_eq(view3[2], 49u8, "1")
    assert_eq(view3[3], 65u8, "A")
    sb.clear()

    // clear_screen -> ESC [ 2 J
    clear_screen(&w)
    w.flush()
    let view4 = sb.as_view()
    assert_eq(view4.len as i32, 4, "clear_screen len")
    assert_eq(view4[2], 50u8, "2")
    assert_eq(view4[3], 74u8, "J")

    sb.deinit()
}

test "colors" {
    let sb = string_builder(64)
    let w = sb.buffered_writer()

    // set_fg(Color.Red) -> ESC [ 3 1 m
    set_fg(&w, Color.Red)
    w.flush()
    let view = sb.as_view()
    assert_eq(view.len as i32, 5, "set_fg len")
    assert_eq(view[0], 27u8, "ESC")
    assert_eq(view[1], 91u8, "[")
    assert_eq(view[2], 51u8, "3")
    assert_eq(view[3], 49u8, "1")
    assert_eq(view[4], 109u8, "m")
    sb.clear()

    // set_bg(Color.Blue) -> ESC [ 4 4 m
    set_bg(&w, Color.Blue)
    w.flush()
    let view2 = sb.as_view()
    assert_eq(view2.len as i32, 5, "set_bg len")
    assert_eq(view2[2], 52u8, "4")
    assert_eq(view2[3], 52u8, "4")
    assert_eq(view2[4], 109u8, "m")
    sb.clear()

    // set_style(Style.Bold) -> ESC [ 1 m
    set_style(&w, Style.Bold)
    w.flush()
    let view3 = sb.as_view()
    assert_eq(view3.len as i32, 4, "set_style len")
    assert_eq(view3[2], 49u8, "1")
    assert_eq(view3[3], 109u8, "m")
    sb.clear()

    // set_fg(Color.Default) -> ESC [ 3 9 m
    set_fg(&w, Color.Default)
    w.flush()
    let view4 = sb.as_view()
    assert_eq(view4.len as i32, 5, "set_fg default len")
    assert_eq(view4[2], 51u8, "3")
    assert_eq(view4[3], 57u8, "9")

    sb.deinit()
}
