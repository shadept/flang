// Buffered I/O primitives.
//
// BufferedWriter and BufferedReader wrap a raw write/read function
// with a caller-provided linear buffer. The buffer auto-flushes (writer)
// or auto-refills (reader) when exhausted. Explicit flush/compact drains
// or shifts remaining data via memmove.
//
// These types are building blocks for File, stdout, network streams, etc.
// The caller owns the backing storage; these structs are borrowed views.

import std.mem

// =============================================================================
// BufferedReader
// =============================================================================

// Raw read function: reads bytes from an OS resource into buf.
// Returns the number of bytes actually read. 0 means EOF.
// ctx: opaque pointer to the underlying resource (fd, handle, etc.)
// buf: slice to read into
pub struct ReadFn {
    ctx: &u8,
    read: fn(ctx: &u8, buf: u8[]) usize
}

// Buffered reader over caller-provided storage.
// Data is read from the OS into buf[0..end] in chunks. The consumer
// reads from buf[pos..end]. When pos == end (all consumed), the buffer
// refills from the OS. If pos > 0 on refill, remaining data is compacted
// to the front via memmove.
pub struct BufferedReader {
    buf: &u8,
    read_fn: ReadFn,
    pos: usize,
    end: usize,
    cap: usize
}

// Create a BufferedReader over the given storage slice.
pub fn buffered_reader(read_fn: ReadFn, storage: u8[]) BufferedReader {
    if (storage.len == 0) {
        // TODO unbuffered reads
        panic("buffered_reader: storage must not be empty")
    }
    return .{
        buf = storage.ptr,
        read_fn = read_fn,
        pos = 0,
        end = 0,
        cap = storage.len
    }
}

// Read up to dst.len bytes into dst.
// Returns the number of bytes read. 0 means EOF.
pub fn read(br: &BufferedReader, dst: u8[]) usize {
    if (dst.len == 0) {
        return 0
    }

    // If buffer is empty, refill first
    if (br.pos == br.end) {
        br.fill()
        if (br.pos == br.end) {
            // EOF: fill got nothing
            return 0
        }
    }

    // Copy from internal buffer to dst
    let avail = br.end - br.pos
    let n = if (dst.len < avail) dst.len else avail
    memcpy(dst.ptr, br.buf + br.pos, n)
    br.pos = br.pos + n
    return n
}

// Read a single byte. Returns the byte in an Option; null on EOF.
pub fn read_byte(br: &BufferedReader) u8? {
    if (br.pos == br.end) {
        br.fill()
        if (br.pos == br.end) {
            return null
        }
    }
    const src = br.buf + br.pos
    let b: u8 = src.*
    br.pos = br.pos + 1
    return b
}

// Internal: refill the buffer from the underlying reader.
// Compacts unconsumed data to the front, then fills the rest.
fn fill(br: &BufferedReader) {
    // Compact: move unconsumed data to the front
    if (br.pos > 0) {
        if (br.end > br.pos) {
            let leftover = br.end - br.pos
            memmove(br.buf, br.buf + br.pos, leftover)
            br.pos = 0
            br.end = leftover
        } else {
            br.pos = 0
            br.end = 0
        }
    }

    // Fill remaining space
    let space = br.cap - br.end
    if (space == 0) {
        return
    }
    const dst = slice_from_raw_parts(br.buf + br.end, space)
    const n = br.read_fn.read(br.read_fn.ctx, dst)
    br.end = br.end + n
}

// =============================================================================
// BufferedWriter
// =============================================================================

// Raw write function: writes bytes to an OS resource.
// Returns the number of bytes actually written.
// ctx: opaque pointer to the underlying resource (fd, handle, etc.)
// data: slice of bytes to write
pub struct WriteFn {
    ctx: &u8
    write: fn(ctx: &u8, data: u8[]) usize
}

// Buffered writer over caller-provided storage.
// Writes accumulate in buf[0..pos]. When pos reaches cap, the buffer
// auto-flushes via the write function. Explicit flush() drains
// any remaining bytes.
pub struct BufferedWriter {
    buf: &u8
    write_fn: WriteFn
    pos: usize
    cap: usize
}

// Create a BufferedWriter over the given storage slice.
pub fn buffered_writer(write_fn: WriteFn, storage: u8[]) BufferedWriter {
    if (storage.len == 0) {
        panic("buffered_writer: storage must not be empty")
    }
    return .{
        buf = storage.ptr,
        write_fn = write_fn,
        pos = 0,
        cap = storage.len
    }
}

// Write data through the buffer.
// Small writes accumulate; the buffer auto-flushes when full.
// Returns the number of bytes written (always data.len on success).
pub fn write(bw: &BufferedWriter, data: u8[]) usize {
    if (data.len == 0) {
        return 0
    }

    let written: usize = 0
    let remaining: usize = data.len

    loop {
        if (remaining == 0) {
            break
        }

        let space = bw.cap - bw.pos

        if (remaining <= space) {
            // Fits in buffer without flushing
            memcpy(bw.buf + bw.pos, data.ptr + written, remaining)
            bw.pos = bw.pos + remaining
            written = written + remaining
            break
        }

        // Fill the rest of the buffer and flush
        memcpy(bw.buf + bw.pos, data.ptr + written, space)
        bw.pos = bw.cap
        bw.flush_all()
        written = written + space
        remaining = remaining - space
    }

    return written
}

// Write a single byte through the buffer.
pub fn write(bw: &BufferedWriter, b: u8) {
    if (bw.pos == bw.cap) {
        bw.flush_all()
    }
    const dest = bw.buf + bw.pos
    dest.* = b
    bw.pos = bw.pos + 1
}

// Flush all buffered data to the underlying write function.
// Resets the buffer position to 0.
pub fn flush(bw: &BufferedWriter) {
    if (bw.pos > 0) {
        bw.flush_all()
    }
}

// Internal: flush the entire buffer contents to the underlying writer.
// Handles partial writes by looping until all bytes are written.
fn flush_all(bw: &BufferedWriter) {
    let flushed: usize = 0
    loop {
        if (flushed >= bw.pos) {
            break
        }
        const chunk = slice_from_raw_parts(bw.buf + flushed, bw.pos - flushed)
        const n = bw.write_fn.write(bw.write_fn.ctx, chunk)
        if (n == 0) {
            panic("buffered_writer: write returned 0")
        }
        flushed = flushed + n
    }
    bw.pos = 0
}
