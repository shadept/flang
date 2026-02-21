// Writer interface and BufferedWriter.
//
// Writer is a vtable interface for raw byte output (write: fn(data: u8[]) usize).
// BufferedWriter wraps a Writer with a caller-provided linear buffer.
// The buffer auto-flushes when full. Explicit flush() drains any remaining bytes.
//
// Building block for File, stdout, network streams, etc.
// The caller owns the backing storage; BufferedWriter is a borrowed view.

import std.mem
import std.interface

// Writer: raw write interface.
// Returns the number of bytes actually written.
// Implement on concrete types via #implement(MyType, Writer).
#interface(Writer, struct {
    write: fn(data: u8[]) usize
})

// Buffered writer over caller-provided storage.
// Writes accumulate in buf[0..pos]. When pos reaches buf.len, the buffer
// auto-flushes via the underlying Writer. Explicit flush() drains
// any remaining bytes.
pub type BufferedWriter = struct {
    inner: Writer
    buf: u8[]
    pos: usize
}

#implement(BufferedWriter, Writer)

// Create a BufferedWriter over the given storage slice.
// If storage is empty, writes flush immediately (unbuffered).
pub fn buffered_writer(w: Writer, storage: u8[]) BufferedWriter {
    return .{
        inner = w,
        buf = storage,
        pos = 0,
    }
}

// Write a single byte through the buffer.
pub fn write(w: &BufferedWriter, b: u8) {
    if w.buf.len == 0 {
        let byte = b
        w.inner.write(slice_from_raw_parts(&byte as &u8, 1))
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
pub fn write(w: &BufferedWriter, data: u8[]) usize {
    if data.len == 0 {
        return 0
    }

    // Unbuffered: write directly
    if w.buf.len == 0 {
        return w.inner.write(data)
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

// Flush all buffered data to the underlying writer.
// Resets the buffer position to 0.
pub fn flush(w: &BufferedWriter) {
    if w.pos > 0 {
        w.flush_all()
    }
}

// Internal: flush the entire buffer contents to the underlying writer.
// Handles partial writes by looping until all bytes are written.
fn flush_all(w: &BufferedWriter) {
    let flushed: usize = 0
    loop {
        if flushed >= w.pos {
            break
        }
        const chunk = slice_from_raw_parts(w.buf.ptr + flushed, w.pos - flushed)
        const n = w.inner.write(chunk)
        if n == 0 {
            panic("writer: write returned 0")
        }
        flushed = flushed + n
    }
    w.pos = 0
}
