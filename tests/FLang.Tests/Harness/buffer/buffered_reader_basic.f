//! TEST: buffered_reader_basic
//! EXIT: 0

import std.io.reader
import std.option

type Source = struct {
    data: u8[],
    pos: usize
}

fn make_source(data: u8[]) Source {
    return Source { data = data, pos = 0 }
}

fn read(self: &Source, buf: u8[]) usize {
    let avail = self.data.len - self.pos
    if (avail == 0) { return 0 }
    let n = if (buf.len < avail) { buf.len } else { avail }
    memcpy(buf.ptr, self.data.ptr + self.pos, n)
    self.pos = self.pos + n
    return n
}

#implement(Source, Reader)

pub fn main() i32 {
    let data: [u8; 5] = [10, 20, 30, 40, 50]
    let src = make_source(data)
    let storage: [u8; 8]

    let br = buffered_reader(src.reader(), storage)

    let b0 = br.read_byte()
    let b0v = b0 match { Some(v) => v, None => return 1 }
    if (b0v != 10) { return 2 }

    let b1 = br.read_byte()
    let b1v = b1 match { Some(v) => v, None => return 3 }
    if (b1v != 20) { return 4 }

    let dst: [u8; 3]
    let n = br.read(dst)
    if (n != 3) { return 5 }
    if (dst[0] != 30) { return 6 }
    if (dst[1] != 40) { return 7 }
    if (dst[2] != 50) { return 8 }

    let eof = br.read_byte()
    if (eof.is_some()) { return 9 }

    return 0
}
