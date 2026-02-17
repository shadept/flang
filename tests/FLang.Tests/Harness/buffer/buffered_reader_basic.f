//! TEST: buffered_reader_basic
//! EXIT: 0

// Test basic BufferedReader: read from in-memory source via fake ReadFn.

import std.io.reader

// Source: serves bytes from a fixed slice, tracking position.
type Source = struct {
    data: u8[],
    pos: usize
}

fn make_source(data: u8[]) Source {
    return Source { data = data, pos = 0 }
}

fn source_read(ctx: &u8, buf: u8[]) usize {
    let src = ctx as &Source
    let avail = src.data.len - src.pos
    if (avail == 0) {
        return 0
    }
    let n = if (buf.len < avail) { buf.len } else { avail }
    memcpy(buf.ptr, src.data.ptr + src.pos, n)
    src.pos = src.pos + n
    return n
}

pub fn main() i32 {
    // Source data: bytes [10, 20, 30, 40, 50]
    let data: [u8; 5] = [10, 20, 30, 40, 50]

    let src = make_source(data)
    let storage: [u8; 8]

    let rfn = ReadFn { ctx = &src as &u8, read = source_read }
    let br = reader(rfn, storage)

    // Read first byte
    let b0 = br.read_byte()
    if (b0.has_value == false) {
        return 1
    }
    if (b0.value != 10) {
        return 2
    }

    // Read second byte
    let b1 = br.read_byte()
    if (b1.has_value == false) {
        return 3
    }
    if (b1.value != 20) {
        return 4
    }

    // Read remaining 3 bytes in bulk
    let dst: [u8; 3]
    let n = br.read(dst)
    if (n != 3) {
        return 5
    }
    if (dst[0] != 30) {
        return 6
    }
    if (dst[1] != 40) {
        return 7
    }
    if (dst[2] != 50) {
        return 8
    }

    // Next read should return EOF (0 bytes)
    let eof = br.read_byte()
    if (eof.has_value == true) {
        return 9
    }

    return 0
}
