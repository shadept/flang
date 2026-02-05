// Buffered reader.
//
// Reader wraps a raw read function with a caller-provided linear buffer.
// The buffer auto-refills when exhausted. Explicit compact shifts remaining
// data via memmove.
//
// Building block for File, stdin, network streams, etc.
// The caller owns the backing storage; this struct is a borrowed view.

import std.mem

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
pub struct Reader {
    buf: &u8,
    read_fn: ReadFn,
    pos: usize,
    end: usize,
    cap: usize
}

// Create a Reader over the given storage slice.
pub fn reader(read_fn: ReadFn, storage: u8[]) Reader {
    if storage.len == 0 {
        // TODO unbuffered reads
        panic("reader: storage must not be empty")
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
pub fn read(r: &Reader, dst: u8[]) usize {
    if dst.len == 0 {
        return 0
    }

    // If buffer has data, serve from it
    if r.pos < r.end {
        let avail = r.end - r.pos
        let n = if dst.len < avail { dst.len } else { avail }
        memcpy(dst.ptr, r.buf + r.pos, n)
        r.pos = r.pos + n
        return n
    }

    // Buffer is empty. If dst is larger than internal storage,
    // bypass the buffer and read directly into dst.
    if dst.len >= r.cap {
        return r.read_fn.read(r.read_fn.ctx, dst)
    }

    // Otherwise refill internal buffer, then copy
    r.fill()
    if r.pos == r.end {
        return 0
    }

    let avail = r.end - r.pos
    let n = if dst.len < avail { dst.len } else { avail }
    memcpy(dst.ptr, r.buf + r.pos, n)
    r.pos = r.pos + n
    return n
}

// Read a single byte. Returns the byte in an Option; null on EOF.
pub fn read_byte(r: &Reader) u8? {
    if r.pos == r.end {
        r.fill()
        if r.pos == r.end {
            return null
        }
    }
    const src = r.buf + r.pos
    let b: u8 = src.*
    r.pos = r.pos + 1
    return b
}

// Internal: refill the buffer from the underlying reader.
// Compacts unconsumed data to the front, then fills the rest.
fn fill(r: &Reader) {
    // Compact: move unconsumed data to the front
    if r.pos > 0 {
        if r.end > r.pos {
            let leftover = r.end - r.pos
            memmove(r.buf, r.buf + r.pos, leftover)
            r.pos = 0
            r.end = leftover
        } else {
            r.pos = 0
            r.end = 0
        }
    }

    // Fill remaining space
    let space = r.cap - r.end
    if space == 0 {
        return
    }
    const dst = slice_from_raw_parts(r.buf + r.end, space)
    const n = r.read_fn.read(r.read_fn.ctx, dst)
    r.end = r.end + n
}
