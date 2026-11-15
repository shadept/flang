//! TEST: channel_try
//! EXIT: 0

// try_send and try_recv never wait, work outside every scope, and report Full, Empty and Closed.

import std.channel
import std.result

fn send_result(r: Result((), TrySendError(i32))) i32 {
    return r match {
        Ok(_) => 0
        Err(e) => e match {
            Full(v) => 100 + v
            Closed(v) => 200 + v
        }
    }
}

fn recv_result(r: Result(i32, TryRecvError)) i32 {
    return r match {
        Ok(v) => v
        Err(e) => e match {
            Empty => -1
            Closed => -2
        }
    }
}

pub fn main() i32 {
    let rendezvous: Channel(i32) = channel()
    if send_result(rendezvous.try_send(5)) != 105 {
        return 1
    }
    if recv_result(rendezvous.try_recv()) != -1 {
        return 2
    }
    rendezvous.deinit()

    let buffered: Channel(i32) = channel(2)
    if send_result(buffered.try_send(1)) != 0 or send_result(buffered.try_send(2)) != 0 {
        return 3
    }
    if send_result(buffered.try_send(3)) != 103 {
        return 4
    }
    if recv_result(buffered.try_recv()) != 1 {
        return 5
    }
    buffered.close()
    if send_result(buffered.try_send(4)) != 204 {
        return 6
    }
    if recv_result(buffered.try_recv()) != 2 or recv_result(buffered.try_recv()) != -2 {
        return 7
    }
    buffered.deinit()
    return 0
}
