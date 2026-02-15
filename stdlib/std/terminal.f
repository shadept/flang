// Terminal management: ANSI escape codes, cursor control, colors, styles.
//
// All output functions write escape sequences to a Writer, so they work
// with any output target (stdout, file, StringBuilder, etc.).

import std.io.writer

// =============================================================================
// Terminal Size
// =============================================================================

pub struct TerminalSize {
    rows: u16
    cols: u16
}

struct Winsize {
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
pub fn move_to(w: &Writer, row: u32, col: u32) {
    write_csi(w)
    write_uint(w, row)
    w.write(b';')
    write_uint(w, col)
    w.write(b'H')
}

// Move cursor up by n lines.  ESC [ n A
pub fn move_up(w: &Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'A')
}

// Move cursor down by n lines.  ESC [ n B
pub fn move_down(w: &Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'B')
}

// Move cursor right by n columns.  ESC [ n C
pub fn move_right(w: &Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'C')
}

// Move cursor left by n columns.  ESC [ n D
pub fn move_left(w: &Writer, n: u32) {
    write_csi(w)
    write_uint(w, n)
    w.write(b'D')
}

// Save cursor position.  ESC [ s
pub fn save_cursor(w: &Writer) {
    write_csi(w)
    w.write(b's')
}

// Restore cursor position.  ESC [ u
pub fn restore_cursor(w: &Writer) {
    write_csi(w)
    w.write(b'u')
}

// Hide cursor.  ESC [ ? 25 l
pub fn hide_cursor(w: &Writer) {
    write_csi(w)
    w.write("?25l")
}

// Show cursor.  ESC [ ? 25 h
pub fn show_cursor(w: &Writer) {
    write_csi(w)
    w.write("?25h")
}

// =============================================================================
// Colors
// =============================================================================

pub enum Color {
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

fn write_color_code(w: &Writer, color: Color) {
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
pub fn set_fg(w: &Writer, color: Color) {
    write_csi(w)
    w.write(b'3')
    write_color_code(w, color)
    w.write(b'm')
}

// Set background color.  ESC [ 4{c} m
pub fn set_bg(w: &Writer, color: Color) {
    write_csi(w)
    w.write(b'4')
    write_color_code(w, color)
    w.write(b'm')
}

// Set bright foreground color.  ESC [ 9{c} m
pub fn set_bright_fg(w: &Writer, color: Color) {
    write_csi(w)
    w.write(b'9')
    write_color_code(w, color)
    w.write(b'm')
}

// Set bright background color.  ESC [ 10{c} m
pub fn set_bright_bg(w: &Writer, color: Color) {
    write_csi(w)
    write_uint(w, 10)
    write_color_code(w, color)
    w.write(b'm')
}

// =============================================================================
// Styles
// =============================================================================

pub enum Style {
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
pub fn set_style(w: &Writer, style: Style) {
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
pub fn reset(w: &Writer) {
    write_csi(w)
    w.write(b'0')
    w.write(b'm')
}

// =============================================================================
// Screen Control
// =============================================================================

// Clear entire screen.  ESC [ 2 J
pub fn clear_screen(w: &Writer) {
    write_csi(w)
    w.write("2J")
}

// Clear from cursor to end of screen.  ESC [ 0 J
pub fn clear_below(w: &Writer) {
    write_csi(w)
    w.write("0J")
}

// Clear from cursor to beginning of screen.  ESC [ 1 J
pub fn clear_above(w: &Writer) {
    write_csi(w)
    w.write("1J")
}

// Clear entire line.  ESC [ 2 K
pub fn clear_line(w: &Writer) {
    write_csi(w)
    w.write("2K")
}

// Clear from cursor to end of line.  ESC [ 0 K
pub fn clear_line_right(w: &Writer) {
    write_csi(w)
    w.write("0K")
}

// Clear from cursor to beginning of line.  ESC [ 1 K
pub fn clear_line_left(w: &Writer) {
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
fn write_csi(w: &Writer) {
    w.write(ESC)
    w.write(b'[')
}

// Write an unsigned integer as decimal digits to a Writer.
fn write_uint(w: &Writer, value: u32) {
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
