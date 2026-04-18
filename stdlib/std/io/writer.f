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
import std.conv

// Writer: raw write interface.
// Returns the number of bytes actually written.
// Implement on concrete types via #implement(MyType, Writer).
#interface(Writer, struct {
    write: fn(data: u8[]) usize
})

// Write a single byte.
pub fn write_byte(self: Writer, b: u8) {
    self.write([b])
}

// Write a string as raw bytes.
pub fn write_str(self: Writer, s: String) {
    self.write(s.as_raw_bytes())
}

// Write an unsigned integer as decimal digits.
pub fn write_uint(self: Writer, value: u64) {
    let buf = [0u8; 20]
    const n = format_u64(value, buf).unwrap()
    self.write(buf[0..n])
}

pub fn write_uint(self: Writer, value: u32) { self.write_uint(value as u64) }
pub fn write_uint(self: Writer, value: usize) { self.write_uint(value as u64) }

// Write a signed integer as decimal digits. Emits a leading '-' for negatives.
pub fn write_int(self: Writer, value: i64) {
    let buf = [0u8; 21]
    const n = format_i64(value, buf).unwrap()
    self.write(buf[0..n])
}

pub fn write_int(self: Writer, value: i32) { self.write_int(value as i64) }
pub fn write_int(self: Writer, value: isize) { self.write_int(value as i64) }

// Write an f64 as decimal digits with up to 6 fractional digits, trailing
// zeros trimmed. For control over width, precision, or alignment, format
// through a StringBuilder instead.
pub fn write_f64(self: Writer, value: f64) {
    // 48 bytes covers `format_f64` at the default precision of 6 (needs 29)
    // with slack for any reasonable precision bump.
    let buf = [0u8; 48]
    const n = format_f64(value, buf).unwrap()
    self.write(buf[0..n])
}

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
