// Buffered writer.
//
// Writer wraps a raw write function with a caller-provided linear buffer.
// The buffer auto-flushes when full. Explicit flush() drains any remaining
// bytes.
//
// Building block for File, stdout, network streams, etc.
// The caller owns the backing storage; this struct is a borrowed view.

import std.mem

// Raw write function: writes bytes to an OS resource.
// Returns the number of bytes actually written.
// ctx: opaque pointer to the underlying resource (fd, handle, etc.)
// data: slice of bytes to write
pub type WriteFn = struct {
    ctx: &u8
    write: fn(ctx: &u8, data: u8[]) usize
}

// Buffered writer over caller-provided storage.
// Writes accumulate in buf[0..pos]. When pos reaches cap, the buffer
// auto-flushes via the write function. Explicit flush() drains
// any remaining bytes.
pub type Writer = struct {
    write_fn: WriteFn
    buf: u8[]
    pos: usize
}

// Create a Writer over the given storage slice.
// If storage is empty, writes flush immediately (unbuffered).
pub fn writer(write_fn: WriteFn, storage: u8[]) Writer {
    return .{
        write_fn = write_fn,
        buf = storage,
        pos = 0,
    }
}

// Write a single byte through the buffer.
pub fn write(w: &Writer, b: u8) {
    if w.buf.len == 0 {
        let byte = b
        w.write_fn.write(w.write_fn.ctx, slice_from_raw_parts(&byte as &u8, 1))
        return
    }

    if w.pos == w.buf.len {
        w.flush_all()
    }

    w.buf[w.pos] = b
    w.pos = w.pos + 1
}

// Write data through the buffer.
// Small writes accumulate; the buffer auto-flushes when full.
// Returns the number of bytes written (always data.len on success).
pub fn write(w: &Writer, data: u8[]) usize {
    if data.len == 0 {
        return 0
    }

    // Unbuffered: write directly
    if w.buf.len == 0 {
        return w.write_fn.write(w.write_fn.ctx, data)
    }

    let written: usize = 0
    let remaining: usize = data.len

    loop {
        if remaining == 0 {
            break
        }

        let space = w.buf.len - w.pos

        if remaining <= space {
            // Fits in buffer without flushing
            //memcpy(w.buf.ptr + w.pos, data.ptr + written, remaining)
            memcpy(w.buf[w.pos..], data.ptr + written, remaining)
            w.pos = w.pos + remaining
            written = written + remaining
            break
        }

        // Fill the rest of the buffer and flush
        memcpy(w.buf.ptr + w.pos, data.ptr + written, space)
        w.pos = w.buf.len
        w.flush_all()
        written = written + space
        remaining = remaining - space
    }

    return written
}

// Flush all buffered data to the underlying write function.
// Resets the buffer position to 0.
pub fn flush(w: &Writer) {
    if w.pos > 0 {
        w.flush_all()
    }
}

// Internal: flush the entire buffer contents to the underlying writer.
// Handles partial writes by looping until all bytes are written.
fn flush_all(w: &Writer) {
    let flushed: usize = 0
    loop {
        if flushed >= w.pos {
            break
        }
        const chunk = slice_from_raw_parts(w.buf.ptr + flushed, w.pos - flushed)
        const n = w.write_fn.write(w.write_fn.ctx, chunk)
        if n == 0 {
            panic("writer: write returned 0")
        }
        flushed = flushed + n
    }
    w.pos = 0
}
