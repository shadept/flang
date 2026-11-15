//! TEST: channel_cancel
//! EXIT: 0

// Cancelling a scope ends a receive and a send waiting on a channel; the send gives its value back.

import std.channel
import std.result
import std.task

fn receive(ch: &Channel(i32)) i32 {
    return ch.recv().await() match {
        Ok(_) => 1
        Err(e) => e match {
            Closed => 2
            Cancelled => 3
        }
    }
}

fn send_forty(ch: &Channel(i32)) i32 {
    return ch.send(40).await() match {
        Ok(_) => 1
        Err(e) => e match {
            Closed(_) => 2
            Cancelled(v) => v
        }
    }
}

pub fn main() i32 {
    let empty: Channel(i32) = channel()
    let full: Channel(i32) = channel(1)
    const r: i32 = concurrent { s =>
        let _seed = full.send(1).await()
        const rx: Task(i32) = s.spawn { receive(&empty) }
        const tx: Task(i32) = s.spawn { send_forty(&full) }
        let _y = yield_now()
        s.cancel()
        rx.await() * 100 + tx.await()
    }
    empty.deinit()
    full.deinit()
    if r != 340 {
        return 1
    }
    return 0
}
