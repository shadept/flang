//! TEST: channel_buffered_close
//! EXIT: 0

// A buffered channel takes sends without a receiver up to its capacity; after a close, sends give
// their value back, receives drain what was sent and then fail, and a second close does nothing.

import std.channel
import std.result
import std.task

fn back(r: Result((), SendError(i32))) i32 {
    return r match {
        Ok(_) => -1
        Err(e) => e match {
            Closed(v) => v
            Cancelled(_) => -2
        }
    }
}

fn received(r: Result(i32, RecvError)) i32 {
    return r match {
        Ok(v) => v
        Err(e) => e match {
            Closed => -1
            Cancelled => -2
        }
    }
}

pub fn main() i32 {
    let ch: Channel(i32) = channel(2)
    const code: i32 = concurrent {
        let failed: i32 = 0
        ch.send(7).await() ?? { failed = 1 }
        ch.send(8).await() ?? { failed = 2 }
        ch.close()
        ch.close()
        if back(ch.send(9).await()) != 9 {
            failed = 3
        }
        if received(ch.recv().await()) != 7 {
            failed = 4
        }
        if received(ch.recv().await()) != 8 {
            failed = 5
        }
        if received(ch.recv().await()) != -1 {
            failed = 6
        }
        failed
    }
    ch.deinit()
    return code
}
