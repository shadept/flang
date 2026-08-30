// LSP position conversion over a `flang_core` line index.
//
// `Position.character` counts units of the negotiated encoding within the line: bytes for utf-8,
// UTF-16 code units for utf-16. The index itself is encoding-independent. A document that is pure
// ASCII (the overwhelming case for FLang source) takes an arithmetic fast path in both directions;
// only utf-16 positions on non-ASCII text walk the line's codepoints.
//
// Out-of-range input is clamped, never rejected: a line past the end maps to the end of the text, a
// character past the line's end maps to the line's end (before its terminator). LSP clients
// routinely send both.

import std.allocator
import std.encoding.utf8
import std.list
import std.option
import std.string
import std.test
// Re-exported: a consumer that wants LSP positions wants the index they are measured against.
pub import flang_core.line_index

pub type PositionEncoding = enum {
    Utf8
    Utf16
}

fn is_utf8(enc: PositionEncoding) bool {
    return enc match { Utf8 => true, else => false }
}

pub type Position = struct {
    line: u32
    character: u32
}

pub fn to_position(self: &LineIndex, text: String, offset: usize, enc: PositionEncoding) Position {
    const off = if offset > self.text_len { self.text_len } else { offset }
    const line = self.line_of(off)
    const start = self.starts[line]

    if self.all_ascii or is_utf8(enc) {
        return .{ line = line as u32, character = (off - start) as u32 }
    }

    // utf-16 over non-ASCII text: count code units from the line start
    const bytes = text.as_raw_bytes()
    let units: usize = 0
    let i = start
    while i < off {
        const decoded = decode_char(bytes[i..bytes.len])
        const width = decoded.1
        if width == 0 or i + width > off {
            break
        }
        const cp = decoded.0 as u32
        const step: usize = if cp >= 0x10000 { 2 } else { 1 }
        units = units + step
        i = i + width
    }
    return .{ line = line as u32, character = units as u32 }
}

pub fn to_offset(self: &LineIndex, text: String, pos: Position, enc: PositionEncoding) usize {
    if pos.line as usize >= self.starts.len {
        return self.text_len
    }
    const bounds = self.line_bounds(text, pos.line as usize)
    const start = bounds.0
    const end = bounds.1

    if self.all_ascii or is_utf8(enc) {
        const want = start + pos.character as usize
        return if want > end { end } else { want }
    }

    const bytes = text.as_raw_bytes()
    let units: usize = 0
    let i = start
    while i < end and units < pos.character as usize {
        const decoded = decode_char(bytes[i..bytes.len])
        const width = decoded.1
        if width == 0 {
            break
        }
        const cp = decoded.0 as u32
        const step: usize = if cp >= 0x10000 { 2 } else { 1 }
        units = units + step
        i = i + width
    }
    return i
}

// Tests

test "ascii offsets round-trip" {
    const text = "let x = 1\nlet y = 2\n"
    let idx = line_index(text)
    defer idx.deinit()

    const p = idx.to_position(text, 14, PositionEncoding.Utf16)
    assert_eq(p.line as usize, 1, "offset 14 is on the second line")
    assert_eq(p.character as usize, 4, "four bytes into it")
    assert_eq(idx.to_offset(text, p, PositionEncoding.Utf16), 14, "and back")
}

test "utf-16 characters count code units, not bytes" {
    // a(1 byte) é(2 bytes, 1 unit) 😀(4 bytes, 2 units) b
    const text = "aé😀b"
    let idx = line_index(text)
    defer idx.deinit()

    const p16 = idx.to_position(text, 7, PositionEncoding.Utf16)
    assert_eq(p16.character as usize, 4, "b is at utf-16 unit 4")
    assert_eq(idx.to_offset(text, p16, PositionEncoding.Utf16), 7, "and back to byte 7")

    const p8 = idx.to_position(text, 7, PositionEncoding.Utf8)
    assert_eq(p8.character as usize, 7, "utf-8 characters are bytes within the line")
    assert_eq(idx.to_offset(text, p8, PositionEncoding.Utf8), 7, "and back")
}

test "out-of-range positions clamp" {
    const text = "ab\ncd"
    let idx = line_index(text)
    defer idx.deinit()

    const past_line = Position { line = 9, character = 0 }
    assert_eq(idx.to_offset(text, past_line, PositionEncoding.Utf16), 5,
        "line past the end clamps to text end")

    const past_char = Position { line = 0, character = 99 }
    assert_eq(idx.to_offset(text, past_char, PositionEncoding.Utf16), 2,
        "character past the line clamps before the terminator")
}

test "crlf terminators are excluded from line content" {
    const text = "ab\r\ncd\r\n"
    let idx = line_index(text)
    defer idx.deinit()

    const past_char = Position { line = 0, character = 99 }
    assert_eq(idx.to_offset(text, past_char, PositionEncoding.Utf16), 2,
        "clamp lands before the \\r")

    const second = Position { line = 1, character = 1 }
    assert_eq(idx.to_offset(text, second, PositionEncoding.Utf16), 5,
        "second line starts after the \\r\\n")
}
