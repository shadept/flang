//! TEST: buffered_writer_basic
//! EXIT: 0

// Test basic BufferedWriter: write small data, flush, verify via sink.

import std.io.writer

// Sink: counts bytes written
struct Sink {
    total: usize
}

fn sink_write(ctx: &u8, data: u8[]) usize {
    let sink = ctx as &Sink
    sink.total = sink.total + data.len
    return data.len
}

fn writer(sink: &Sink, buffer: u8[]) Writer {
    const wfn = WriteFn { ctx = &sink as &u8, write = sink_write }
    return writer(wfn, buffer)
}

pub fn main() i32 {
    let sink = Sink { total = 0 }
    let storage: [u8; 16]
    let w = sink.writer(storage)

    // Write "hello" (5 bytes) - should stay in buffer
    w.write("hello")
    if (sink.total != 0) {
        return 1
    }
    if (w.pos != 5) {
        return 2
    }

    // Flush - should push 5 bytes to sink
    w.flush()
    if (sink.total != 5) {
        return 3
    }
    if (w.pos != 0) {
        return 4
    }

    return 0
}
