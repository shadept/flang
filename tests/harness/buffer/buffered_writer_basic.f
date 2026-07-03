//! TEST: buffered_writer_basic
//! EXIT: 0

import std.io.writer

type Sink = struct {
    total: usize
}

fn write(self: &Sink, data: u8[]) usize {
    self.total = self.total + data.len
    return data.len
}

#implement(Sink, Writer)

pub fn main() i32 {
    let sink = Sink { total = 0 }
    let storage: [u8; 16]
    let w = buffered_writer(sink.writer(), storage)

    w.write("hello")
    if (sink.total != 0) { return 1 }
    if (w.pos != 5) { return 2 }

    w.flush()
    if (sink.total != 5) { return 3 }
    if (w.pos != 0) { return 4 }

    return 0
}
