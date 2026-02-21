//! TEST: buffered_writer_autoflush
//! EXIT: 0

import std.io.writer

type Sink = struct {
    total: usize,
    flush_count: usize
}

fn write(self: &Sink, data: u8[]) usize {
    self.total = self.total + data.len
    self.flush_count = self.flush_count + 1
    return data.len
}

#implement(Sink, Writer)

pub fn main() i32 {
    let sink = Sink { total = 0, flush_count = 0 }
    let storage: [u8; 4]

    let bw = buffered_writer(sink.writer(), storage)

    bw.write("abcdefgh")

    if (sink.total != 4) { return 1 }
    if (bw.pos != 4) { return 2 }

    bw.flush()
    if (sink.total != 8) { return 3 }
    if (bw.pos != 0) { return 4 }
    if (sink.flush_count != 2) { return 5 }

    return 0
}
