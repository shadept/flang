//! TEST: buffered_writer_autoflush
//! EXIT: 0

// Test BufferedWriter auto-flush when buffer fills up.

import std.io.writer

struct Sink {
    total: usize,
    flush_count: usize
}

fn sink_write(ctx: &u8, data: u8[]) usize {
    let sink = ctx as &Sink
    sink.total = sink.total + data.len
    sink.flush_count = sink.flush_count + 1
    return data.len
}

pub fn main() i32 {
    let sink = Sink { total = 0, flush_count = 0 }
    // Tiny 4-byte buffer to force auto-flush
    let storage: [u8; 4]

    let wfn = WriteFn { ctx = &sink as &u8, write = sink_write }
    let bw = writer(wfn, storage)

    // Write "abcdefgh" (8 bytes) into a 4-byte buffer.
    // Should auto-flush at least once (when first 4 bytes fill buffer),
    // then buffer the remaining 4.
    bw.write("abcdefgh")

    // After write: 4 bytes flushed to sink, 4 bytes pending
    if (sink.total != 4) {
        return 1
    }
    if (bw.pos != 4) {
        return 2
    }

    // Explicit flush drains the rest
    bw.flush()
    if (sink.total != 8) {
        return 3
    }
    if (bw.pos != 0) {
        return 4
    }

    // Verify flush was called twice total
    if (sink.flush_count != 2) {
        return 5
    }

    return 0
}
