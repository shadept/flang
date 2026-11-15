//! TEST: channel_rendezvous
//! EXIT: 0

// Values sent on a zero-capacity channel arrive in order, and a receive fails once the channel is
// closed.

import std.channel
import std.result
import std.task

fn produce(ch: &Channel(i32)) i32 {
    for i in 1i32..6i32 {
        ch.send(i).await() ?? return -1
    }
    ch.close()
    return 0
}

fn consume(ch: &Channel(i32)) i32 {
    let total: i32 = 0
    loop {
        const v: i32 = ch.recv().await() ?? break
        total = total * 10 + v
    }
    return total
}

pub fn main() i32 {
    let ch: Channel(i32) = channel()
    const total: i32 = concurrent { s =>
        const p: Task(i32) = s.spawn { produce(&ch) }
        const c: Task(i32) = s.spawn { consume(&ch) }
        p.await() + c.await()
    }
    ch.deinit()
    if total != 12345 {
        return 1
    }
    return 0
}
