// Reader interface and BufferedReader.
//
// Reader is a vtable interface for raw byte input (read: fn(buf: u8[]) usize). BufferedReader wraps
// a Reader with a caller-provided linear buffer. The buffer auto-refills when exhausted. Explicit
// compact shifts remaining data via memmove.
//
// Building block for File, stdin, network streams, etc. The caller owns the backing storage;
// BufferedReader is a borrowed view.

import std.allocator
import std.mem
import std.interface
import std.string
import std.string_builder
import std.string_reader
import std.test

// Reader: raw read interface.
// Returns the number of bytes actually read. 0 means EOF. Implement on concrete types via
// #implement(MyType, Reader).
#interface(Reader, struct {
    read: fn(buf: u8[]) usize
})

// Buffered reader over caller-provided storage.
// Data is read from the OS into buf[0..end] in chunks. The consumer reads from buf[pos..end]. When
// pos == end (all consumed), the buffer refills from the OS. If pos > 0 on refill, remaining data
// is compacted to the front via memmove.
pub type BufferedReader = struct {
    inner: Reader
    buf: u8[]
    pos: usize
    end: usize
}

#implement(BufferedReader, Reader)

// Create a BufferedReader over the given storage slice. If storage is empty, reads pass through
// directly (unbuffered).
pub fn buffered_reader(r: Reader, storage: u8[]) BufferedReader {
    return .{
        inner = r,
        buf = storage,
        pos = 0,
        end = 0,
    }
}

// Read a single byte. Returns the byte in an Option; null on EOF.
pub fn read_byte(r: &BufferedReader) u8? {
    // Unbuffered: read 1 byte directly
    if r.buf.len == 0 {
        let b: u8 = 0
        const dst = slice_from_raw_parts(&b as &u8, 1)
        const n = r.inner.read(dst)
        if n == 0 {
            return null
        }
        return Some(b)
    }

    if r.pos == r.end {
        r.fill()
        if r.pos == r.end {
            return null
        }
    }
    const src = r.buf.ptr + r.pos
    let b: u8 = src.*
    r.pos = r.pos + 1
    return Some(b)
}

// Read up to dst.len bytes into dst.
// Returns the number of bytes read. 0 means EOF.
pub fn read(r: &BufferedReader, dst: u8[]) usize {
    if dst.len == 0 {
        return 0
    }

    // Unbuffered: passthrough to underlying reader
    if r.buf.len == 0 {
        return r.inner.read(dst)
    }

    // If buffer has data, serve from it
    if r.pos < r.end {
        let avail = r.end - r.pos
        let n = if dst.len < avail { dst.len } else { avail }
        memcpy(dst.ptr, r.buf.ptr + r.pos, n)
        r.pos = r.pos + n
        return n
    }

    // Buffer is empty. If dst is larger than internal storage, bypass the buffer and read directly
    // into dst.
    if dst.len >= r.buf.len {
        return r.inner.read(dst)
    }

    // Otherwise refill internal buffer, then copy
    r.fill()
    if r.pos == r.end {
        return 0
    }

    let avail = r.end - r.pos
    let n = if dst.len < avail { dst.len } else { avail }
    memcpy(dst.ptr, r.buf.ptr + r.pos, n)
    r.pos = r.pos + n
    return n
}

// Read `r` to EOF into a fresh OwnedString. Bytes are taken as-is - no encoding checks.
pub fn read_all(r: Reader, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(4096, allocator)
    let buf = [0u8; 4096]
    loop {
        const n = r.read(buf as u8[])
        if n == 0 {
            break
        }
        sb.append_bytes(buf[0..n])
    }
    return sb.to_string()
}

// Internal: refill the buffer from the underlying reader. Compacts unconsumed data to the front,
// then fills the rest.
fn fill(r: &BufferedReader) {
    // Compact: move unconsumed data to the front
    if r.pos > 0 {
        if r.end > r.pos {
            let leftover = r.end - r.pos
            memmove(r.buf.ptr, r.buf.ptr + r.pos, leftover)
            r.pos = 0
            r.end = leftover
        } else {
            r.pos = 0
            r.end = 0
        }
    }

    // Fill remaining space
    let space = r.buf.len - r.end
    if space == 0 {
        return
    }
    const dst = r.buf[r.end..]
    const n = r.inner.read(dst)
    r.end = r.end + n
}

// Tests

test "read_all drains a reader to EOF" {
    let r = mem_reader("hello, reader")
    let out = read_all(r.reader())
    defer out.deinit()
    assert_true(out.as_view() == "hello, reader", "everything arrives, nothing extra")
}

test "read_all crosses the internal chunk size" {
    let sb = string_builder(9600)
    sb.append_repeated("abcdefgh", 1200)
    let src = sb.to_string()
    defer src.deinit()
    let r = mem_reader(src.as_view())
    let out = read_all(r.reader())
    defer out.deinit()
    assert_eq(out.len, src.len, "a payload larger than one chunk arrives whole")
    assert_true(out.as_view() == src.as_view(), "byte for byte")
}
