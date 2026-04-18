// Interactive line editor with arrow key navigation and history.
//
// Usage:
//   let rl = readline("> ", 64)
//   defer rl.deinit()
//   loop {
//       const line = rl.read_line()
//       if line.is_none() { break }  // EOF (Ctrl-D)
//       process(line.value)
//   }

import std.option
import std.mem

// =============================================================================
// FFI
// =============================================================================

// Cross-platform
#foreign fn isatty(fd: i32) i32
#foreign fn read(fd: i32, buf: &u8, len: usize) isize
#foreign fn write(fd: i32, buf: &u8, len: usize) isize

// POSIX terminal control (unused on Windows — externs emitted but unreferenced)
#foreign fn tcgetattr(fd: i32, termios_p: &u8) i32
#foreign fn tcsetattr(fd: i32, actions: i32, termios_p: &u8) i32

// Windows console API (unused on POSIX — externs emitted but unreferenced)
#foreign fn GetStdHandle(nStdHandle: u32) usize
#foreign fn GetConsoleMode(hConsole: usize, lpMode: &u32) i32
#foreign fn SetConsoleMode(hConsole: usize, dwMode: u32) i32
#foreign fn ReadFile(hFile: usize, lpBuffer: &u8, nBytes: u32, lpBytesRead: &u32, lpOverlapped: usize) i32

const TCSAFLUSH: i32 = 2

// macOS arm64 termios layout (72 bytes):
//   c_iflag:  offset 0,  size 8 (u64)
//   c_oflag:  offset 8,  size 8 (u64)
//   c_cflag:  offset 16, size 8 (u64)
//   c_lflag:  offset 24, size 8 (u64)
//   c_cc:     offset 32, size 20
//   _pad:     offset 52, size 4
//   c_ispeed: offset 56, size 8 (u64)
//   c_ospeed: offset 64, size 8 (u64)
const TERMIOS_SIZE: usize = 72
const LFLAG_OFFSET: usize = 24
const CC_OFFSET: usize = 32

// c_lflag bits
const ECHO: u64 = 8
const ICANON: u64 = 256
const ISIG: u64 = 128

// c_cc indices
const VMIN: usize = 16
const VTIME: usize = 17

// Windows console mode constants
const WIN_STD_INPUT_HANDLE: u32 = 0xFFFFFFF6
const WIN_STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5
const WIN_ENABLE_PROCESSED_INPUT: u32 = 1
const WIN_ENABLE_LINE_INPUT: u32 = 2
const WIN_ENABLE_ECHO_INPUT: u32 = 4
const WIN_ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 512
const WIN_ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 4

// =============================================================================
// Key codes
// =============================================================================

type Key = enum {
    Char(u8)
    Left
    Right
    Up
    Down
    Home
    End
    Delete
    Backspace
    Enter
    Eof
    Unknown
}

// =============================================================================
// History
// =============================================================================

const MAX_HISTORY: usize = 128

type History = struct {
    entries: [u8; 16384]  // flat buffer: length-prefixed strings packed together
    offsets: [usize; 128] // offset of each entry in the buffer
    count: usize
    buf_used: usize
}

fn history() History {
    let h = History {
        entries = [0u8; 16384],
        offsets = [0usize; 128],
        count = 0,
        buf_used = 0
    }
    return h
}

fn history_add(h: &History, line: String) {
    if line.len == 0 { return }

    // Don't add duplicates of the most recent entry
    if h.count > 0 {
        const last_off = h.offsets[h.count - 1]
        const last_len = h.entries[last_off] as usize
        if last_len == line.len {
            let same = true
            for i in 0..last_len {
                if h.entries[last_off + 1 + i] != line[i] {
                    same = false
                    break
                }
            }
            if same { return }
        }
    }

    // Need 1 byte for length + line.len bytes
    const needed = 1 + line.len
    if h.buf_used + needed > 16384 { return } // buffer full, skip

    if h.count >= MAX_HISTORY {
        // Shift everything down by removing the oldest entry
        const first_len = h.entries[0] as usize
        const remove = 1 + first_len
        memcpy(&h.entries[0], &h.entries[remove], h.buf_used - remove)
        h.buf_used = h.buf_used - remove
        // Shift offsets
        for i in 0..(h.count - 1) {
            h.offsets[i] = h.offsets[i + 1] - remove
        }
        h.count = h.count - 1
    }

    const off = h.buf_used
    h.offsets[h.count] = off
    h.entries[off] = line.len as u8
    for i in 0..line.len {
        h.entries[off + 1 + i] = line[i]
    }
    h.buf_used = h.buf_used + needed
    h.count = h.count + 1
}

fn history_get(h: &History, index: usize) String {
    if index >= h.count { return "" }
    const off = h.offsets[index]
    const len = h.entries[off] as usize
    return slice_from_raw_parts(&h.entries[off + 1], len) as String
}

// =============================================================================
// Readline state
// =============================================================================

pub type Readline = struct {
    prompt: String
    hist: History
    raw_buf: [u8; 72]        // saved original termios
    line_buf: [u8; 1024]     // persistent buffer for returned line data
    is_raw: bool
}

pub fn readline(prompt: String) Readline {
    let rl = Readline {
        prompt = prompt,
        hist = history(),
        raw_buf = [0u8; 72],
        line_buf = [0u8; 1024],
        is_raw = false
    }
    return rl
}

pub fn deinit(self: &Readline) {
    if self.is_raw {
        disable_raw(self)
    }
}

// =============================================================================
// Raw mode
// =============================================================================

fn enable_raw(rl: &Readline) {
    if rl.is_raw { return }
    if isatty(0) == 0 { return }

    #if(platform.os == "windows") {
        // Save original console modes (stdin in bytes 0..3, stdout in bytes 4..7)
        const hIn = GetStdHandle(WIN_STD_INPUT_HANDLE)
        let in_mode: u32 = 0
        GetConsoleMode(hIn, &in_mode)
        const p_in = &rl.raw_buf[0] as &u32
        p_in.* = in_mode

        const hOut = GetStdHandle(WIN_STD_OUTPUT_HANDLE)
        let out_mode: u32 = 0
        GetConsoleMode(hOut, &out_mode)
        const p_out = &rl.raw_buf[4] as &u32
        p_out.* = out_mode

        // Disable echo and line input, enable VT input for escape sequences
        const new_in = (in_mode & (0xFFFFFFFF - WIN_ENABLE_ECHO_INPUT - WIN_ENABLE_LINE_INPUT - WIN_ENABLE_PROCESSED_INPUT)) | WIN_ENABLE_VIRTUAL_TERMINAL_INPUT
        SetConsoleMode(hIn, new_in)

        // Enable VT processing on stdout for ANSI escape codes
        SetConsoleMode(hOut, out_mode | WIN_ENABLE_VIRTUAL_TERMINAL_PROCESSING)
    } else {
        // Save original termios
        tcgetattr(0, &rl.raw_buf[0])

        // Copy and modify
        let raw = [0u8; 72]
        memcpy(&raw[0], &rl.raw_buf[0], TERMIOS_SIZE)

        // Clear ECHO, ICANON, ISIG from c_lflag
        let lflag = read_u64(&raw[LFLAG_OFFSET])
        lflag = lflag & (0xFFFFFFFFFFFFFFFF - ECHO - ICANON - ISIG)
        write_u64(&raw[LFLAG_OFFSET], lflag)

        // Set VMIN=1, VTIME=0
        raw[CC_OFFSET + VMIN] = 1
        raw[CC_OFFSET + VTIME] = 0

        tcsetattr(0, TCSAFLUSH, &raw[0])
    }

    rl.is_raw = true
}

fn disable_raw(rl: &Readline) {
    if !rl.is_raw { return }

    #if(platform.os == "windows") {
        const hIn = GetStdHandle(WIN_STD_INPUT_HANDLE)
        const p_in = &rl.raw_buf[0] as &u32
        SetConsoleMode(hIn, p_in.*)

        const hOut = GetStdHandle(WIN_STD_OUTPUT_HANDLE)
        const p_out = &rl.raw_buf[4] as &u32
        SetConsoleMode(hOut, p_out.*)
    } else {
        tcsetattr(0, TCSAFLUSH, &rl.raw_buf[0])
    }

    rl.is_raw = false
}

fn read_u64(ptr: &u8) u64 {
    const p = ptr as &u64
    return p.*
}

fn write_u64(ptr: &u8, val: u64) {
    const p = ptr as &u64
    p.* = val
}

// =============================================================================
// Key reading
// =============================================================================

fn read_byte() u8? {
    let c: u8 = 0
    #if(platform.os == "windows") {
        // Use ReadFile directly — CRT _read ignores SetConsoleMode changes
        const hIn = GetStdHandle(WIN_STD_INPUT_HANDLE)
        let bytes_read: u32 = 0
        const ok = ReadFile(hIn, &c, 1, &bytes_read, 0)
        if ok == 0 or bytes_read == 0 { return null }
    } else {
        const n = read(0, &c, 1)
        if n <= 0 { return null }
    }
    return c
}

fn read_key() Key {
    const c = read_byte()
    if c.is_none() { return Key.Eof }
    const b = c.value

    if b == 13 or b == 10 { return Key.Enter }
    if b == 127 or b == 8 { return Key.Backspace }
    if b == 4 { return Key.Eof }   // Ctrl-D

    // Escape sequences
    if b == 27 {
        const c2 = read_byte()
        if c2.is_none() { return Key.Unknown }
        if c2.value != b'[' { return Key.Unknown }

        const c3 = read_byte()
        if c3.is_none() { return Key.Unknown }

        if c3.value == b'A' { return Key.Up }
        if c3.value == b'B' { return Key.Down }
        if c3.value == b'C' { return Key.Right }
        if c3.value == b'D' { return Key.Left }
        if c3.value == b'H' { return Key.Home }
        if c3.value == b'F' { return Key.End }

        // ESC [ 3 ~ = Delete
        if c3.value == b'3' {
            const c4 = read_byte()
            if c4.is_some() and c4.value == b'~' { return Key.Delete }
        }

        return Key.Unknown
    }

    // Regular printable character
    if b >= 32 and b < 127 { return Key.Char(b) }

    return Key.Unknown
}

// =============================================================================
// Line editing
// =============================================================================

pub fn read_line(rl: &Readline) String? {
    if isatty(0) == 0 {
        return read_line_simple(rl)
    }

    enable_raw(rl)

    // Print prompt
    write(1, rl.prompt.ptr, rl.prompt.len)

    let buf = [0u8; 1024]
    let len: usize = 0
    let cursor: usize = 0
    let hist_index: isize = -1  // -1 = current input, 0..n = history
    let saved_buf = [0u8; 1024] // saved current input when browsing history
    let saved_len: usize = 0

    loop {
        const key = read_key()

        key match {
            Enter => {
                write_str("\r\n")
                disable_raw(rl)
                // Copy into persistent buffer so the returned String outlives this call
                memcpy(&rl.line_buf[0], &buf[0], len)
                const line = slice_from_raw_parts(&rl.line_buf[0], len) as String
                if len > 0 { history_add(&rl.hist, line) }
                return line
            },

            Eof => {
                if len == 0 {
                    write_str("\r\n")
                    disable_raw(rl)
                    return null
                }
            },

            Char(c) => {
                if len < 1023 {
                    // Insert at cursor position
                    if cursor < len {
                        // Shift right
                        let i = len
                        while i > cursor {
                            buf[i] = buf[i - 1]
                            i = i - 1
                        }
                    }
                    buf[cursor] = c
                    len = len + 1
                    cursor = cursor + 1
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Backspace => {
                if cursor > 0 {
                    // Shift left
                    for i in (cursor - 1)..(len - 1) {
                        buf[i] = buf[i + 1]
                    }
                    len = len - 1
                    cursor = cursor - 1
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Delete => {
                if cursor < len {
                    for i in cursor..(len - 1) {
                        buf[i] = buf[i + 1]
                    }
                    len = len - 1
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Left => {
                if cursor > 0 {
                    cursor = cursor - 1
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Right => {
                if cursor < len {
                    cursor = cursor + 1
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Home => {
                cursor = 0
                refresh_line(rl, buf, len, cursor)
            },

            End => {
                cursor = len
                refresh_line(rl, buf, len, cursor)
            },

            Up => {
                if rl.hist.count > 0 {
                    if hist_index == -1 {
                        // Save current input
                        memcpy(&saved_buf[0], &buf[0], len)
                        saved_len = len
                        hist_index = rl.hist.count as isize - 1
                    } else if hist_index > 0 {
                        hist_index = hist_index - 1
                    } else {
                        continue
                    }
                    const entry = history_get(&rl.hist, hist_index as usize)
                    memcpy(&buf[0], entry.ptr, entry.len)
                    len = entry.len
                    cursor = len
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Down => {
                if hist_index >= 0 {
                    hist_index = hist_index + 1
                    if hist_index as usize >= rl.hist.count {
                        // Restore saved input
                        hist_index = -1
                        memcpy(&buf[0], &saved_buf[0], saved_len)
                        len = saved_len
                        cursor = len
                    } else {
                        const entry = history_get(&rl.hist, hist_index as usize)
                        memcpy(&buf[0], entry.ptr, entry.len)
                        len = entry.len
                        cursor = len
                    }
                    refresh_line(rl, buf, len, cursor)
                }
            },

            Unknown => {}
        }
    }

    disable_raw(rl)
    return null
}

fn refresh_line(rl: &Readline, buf: [u8; 1024], len: usize, cursor: usize) {
    // Move to start of line, clear it, rewrite prompt + buffer, reposition cursor
    let out = [0u8; 2048]
    let pos: usize = 0

    // \r — carriage return
    out[pos] = 13; pos = pos + 1

    // Write prompt
    for i in 0..rl.prompt.len {
        out[pos] = rl.prompt[i]; pos = pos + 1
    }

    // Write buffer content
    for i in 0..len {
        out[pos] = buf[i]; pos = pos + 1
    }

    // Clear to end of line: ESC [ K
    out[pos] = 27; pos = pos + 1
    out[pos] = b'['; pos = pos + 1
    out[pos] = b'K'; pos = pos + 1

    // Move cursor to correct position: \r then ESC [ {n} C
    out[pos] = 13; pos = pos + 1
    const target = rl.prompt.len + cursor
    if target > 0 {
        out[pos] = 27; pos = pos + 1
        out[pos] = b'['; pos = pos + 1
        // Write target as decimal digits
        pos = write_uint_to_buf(out, pos, target as u32)
        out[pos] = b'C'; pos = pos + 1
    }

    write(1, &out[0], pos)
}

fn write_uint_to_buf(buf: [u8; 2048], start: usize, value: u32) usize {
    if value == 0 {
        buf[start] = b'0'
        return start + 1
    }
    let digits = [0u8; 10]
    let count: usize = 0
    let v = value
    while v != 0 {
        digits[count] = b'0' + (v % 10) as u8
        v = v / 10
        count = count + 1
    }
    let pos = start
    let i = count
    while i != 0 {
        i = i - 1
        buf[pos] = digits[i]
        pos = pos + 1
    }
    return pos
}

fn write_str(s: String) {
    write(1, s.ptr, s.len)
}

// Simple non-interactive fallback for piped input
fn read_line_simple(rl: &Readline) String? {
    let len: usize = 0

    loop {
        let c: u8 = 0
        const n = read(0, &c, 1)
        if n <= 0 {
            if len == 0 { return null }
            break
        }
        if c == b'\n' { break }
        if len < 1023 {
            rl.line_buf[len] = c
            len = len + 1
        }
    }

    return slice_from_raw_parts(&rl.line_buf[0], len) as String
}
