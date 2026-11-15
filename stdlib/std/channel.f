// std.channel passes values between tasks (RFC-005).
//
// A channel is a queue of values that tasks send into and receive from, in order. A channel made
// with a capacity of zero holds no values: a send waits until a receiver takes its value. A channel
// with a positive capacity holds up to that many values, and a send waits only while it is full. A
// receive waits until a value is available.
//
// Closing a channel ends it. Sends after the close fail and give their value back; receives take
// the values already sent, then fail. Closing a closed channel does nothing.
//
// A send or receive is an operation that `.await()` completes, waiting as described above. While it
// waits, cancelling the task's scope ends the wait with a cancellation error, and a send gives its
// value back. `try_send` and `try_recv` never wait: they complete at once or fail.

import std.allocator
import std.collections.deque
import std.option
import std.result
import std.runtime.coro
import std.string
import std.task
import std.test

// A Channel carries values of type `T` between tasks. Tasks share it by reference; its owner
// releases it with `deinit` once no task uses it.
pub type Channel = struct(T) {
    owned __state: &ChannelState(T)
}

// RecvError is why a receive failed.
pub type RecvError = enum {
    // The channel is closed and holds no more values.
    Closed
    // The receiving task's scope was cancelled while it waited.
    Cancelled
}

// SendError is why a send failed. It gives back the value that was not sent.
pub type SendError = enum(T) {
    // The channel was closed before the value was taken.
    Closed(T)
    // The sending task's scope was cancelled while it waited.
    Cancelled(T)
}

// Releases the value the error gave back.
pub fn deinit(self: move SendError($T)) {
    self match {
        Closed(v) => release(v)
        Cancelled(v) => release(v)
    }
}

// TrySendError is why a send that does not wait failed. It gives back the value that was not sent.
pub type TrySendError = enum(T) {
    // No receiver was waiting and the channel had no room.
    Full(T)
    // The channel is closed.
    Closed(T)
}

// Releases the value the error gave back.
pub fn deinit(self: move TrySendError($T)) {
    self match {
        Full(v) => release(v)
        Closed(v) => release(v)
    }
}

// TryRecvError is why a receive that does not wait failed.
pub type TryRecvError = enum {
    // The channel is open but holds no value, and no sender is waiting.
    Empty
    // The channel is closed and holds no more values.
    Closed
}

// SendOp is a send not yet performed; `.await()` performs it.
pub type SendOp = struct(T) {
    __channel: &Channel(T)
    __value: T
}

// RecvOp is a receive not yet performed; `.await()` performs it.
pub type RecvOp = struct(T) {
    __channel: &Channel(T)
}

// WaitStatus is how a waiting operation's wait ended: not yet, by delivery, or by the channel
// closing.
type WaitStatus = enum {
    Waiting
    Done
    Closed
}

// SendWaiter is a sender waiting for room or for a receiver. It lives on the sender's stack while
// the sender waits.
type SendWaiter = struct(T) {
    coroutine: &Coroutine
    // The value being sent, still in the sender's frame; a receiver moves it out.
    owned value: &T
    status: WaitStatus
    next: &SendWaiter(T)?
}

// RecvWaiter is a receiver waiting for a value. It lives on the receiver's stack while the receiver
// waits.
type RecvWaiter = struct(T) {
    coroutine: &Coroutine
    // Where a sender stores the value, in the receiver's frame.
    owned slot: &T
    status: WaitStatus
    next: &RecvWaiter(T)?
}

// ChannelState is a channel's buffer and its queues of waiting senders and receivers. At most one
// of the two queues is non-empty at a time, and receivers wait only while the buffer is empty.
type ChannelState = struct(T) {
    buffer: Deque(T)
    cap: usize
    closed: bool
    senders: &SendWaiter(T)?
    receivers: &RecvWaiter(T)?
    allocator: &Allocator
}

// Returns a channel holding up to `capacity` values, its memory from `allocator`. A capacity of
// zero makes every send wait for a receiver.
pub fn channel(capacity: usize = 0, allocator: &Allocator = context.allocator) Channel($T) {
    const state = box(
        allocator,
        ChannelState(T) {
            buffer = deque(capacity, allocator),
            cap = capacity,
            closed = false,
            senders = null,
            receivers = null,
            allocator = allocator,
        },
    )
    return .{ __state = state }
}

// Returns an operation that sends `value` on the channel when awaited.
pub fn send(self: &Channel($T), value: move T) SendOp(T) {
    return .{ __channel = self, __value = move value }
}

// Returns an operation that receives a value from the channel when awaited.
pub fn recv(self: &Channel($T)) RecvOp(T) {
    return .{ __channel = self }
}

// Sends `value` if it can be taken at once: by a waiting receiver, or into free room. Never waits,
// and may be called outside every scope.
//
// Returns `Err(Full(value))` if neither is possible and `Err(Closed(value))` if the channel is
// closed.
pub fn try_send(self: &Channel($T), value: move T) Result((), TrySendError(T)) {
    const s = self.__state
    if s.closed {
        return Err(TrySendError.Closed(move value))
    }
    take_receiver(s) match {
        Some(r) => {
            r.slot.* = move value
            r.status = WaitStatus.Done
            r.coroutine.wake()
            return Ok(())
        }
        None => {}
    }
    if s.buffer.len < s.cap {
        s.buffer.push_back(value)
        return Ok(())
    }
    return Err(TrySendError.Full(move value))
}

// Receives a value if one is ready: in the channel's buffer, or from a waiting sender. Never waits,
// and may be called outside every scope.
//
// Returns `Err(Empty)` if no value is ready and the channel is open, and `Err(Closed)` once it is
// closed and holds no more values.
pub fn try_recv(self: &Channel($T)) Result(T, TryRecvError) {
    const s = self.__state
    s.buffer.pop_front() match {
        Some(v) => {
            take_sender(s) match {
                Some(w) => {
                    s.buffer.push_back(w.value.*)
                    w.status = WaitStatus.Done
                    w.coroutine.wake()
                }
                None => {}
            }
            return Ok(move v)
        }
        None => {}
    }
    take_sender(s) match {
        Some(w) => {
            const v = move w.value.*
            w.status = WaitStatus.Done
            w.coroutine.wake()
            return Ok(move v)
        }
        None => {}
    }
    if s.closed {
        return Err(TryRecvError.Closed)
    }
    return Err(TryRecvError.Empty)
}

// Sends the operation's value. Blocks the calling task until a receiver takes it, or, on a channel
// with capacity, until there is room. Returns at once if a receiver is waiting or there is room.
//
// Returns `Err(Closed(value))` if the channel is or becomes closed before the value is taken, and
// `Err(Cancelled(value))` if the task's scope is cancelled before then.
//
// Panics if called outside every scope.
pub fn await(self: move SendOp($T)) Result((), SendError(T)) {
    const ch = self.__channel
    if context.job.is_cancelled() {
        return Err(SendError.Cancelled(move self.__value))
    }
    let value = ch.try_send(self.__value) match {
        Ok(_) => return Ok(())
        Err(e) => e match {
            Full(v) => move v
            Closed(v) => return Err(SendError.Closed(move v))
        }
    }
    const me = current_coroutine() match {
        Some(c) => c
        None => panic("send: outside a concurrent scope")
    }
    let w = SendWaiter(T) {
        coroutine = me,
        value = &value,
        status = WaitStatus.Waiting,
        next = null,
    }
    add_sender(ch.__state, &w)
    loop {
        park()
        w.status match {
            Done => {
                leak(w)
                leak(value)
                return Ok(())
            }
            Closed => {
                leak(w)
                return Err(SendError.Closed(move value))
            }
            Waiting => {
                if context.job.is_cancelled() {
                    remove_sender(ch.__state, &w)
                    leak(w)
                    return Err(SendError.Cancelled(move value))
                }
            }
        }
    }
}

// Receives a value. Blocks the calling task until a value is available. Returns at once if the
// channel holds one or a sender is waiting.
//
// Returns `Err(Closed)` once the channel is closed and holds no more values, and `Err(Cancelled)`
// if the task's scope is cancelled before a value arrives.
//
// Panics if called outside every scope.
pub fn await(self: move RecvOp($T)) Result(T, RecvError) {
    const ch = self.__channel
    if context.job.is_cancelled() {
        return Err(RecvError.Cancelled)
    }
    ch.try_recv() match {
        Ok(v) => return Ok(move v)
        Err(e) => e match {
            Closed => return Err(RecvError.Closed)
            Empty => {}
        }
    }
    const me = current_coroutine() match {
        Some(c) => c
        None => panic("recv: outside a concurrent scope")
    }
    let received: T
    let w = RecvWaiter(T) {
        coroutine = me,
        slot = &received,
        status = WaitStatus.Waiting,
        next = null,
    }
    add_receiver(ch.__state, &w)
    loop {
        park()
        w.status match {
            Done => {
                leak(w)
                return Ok(move received)
            }
            Closed => {
                leak(w)
                leak(received)
                return Err(RecvError.Closed)
            }
            Waiting => {
                if context.job.is_cancelled() {
                    remove_receiver(ch.__state, &w)
                    leak(w)
                    leak(received)
                    return Err(RecvError.Cancelled)
                }
            }
        }
    }
}

// Closes the channel. Waiting receivers fail with `Closed`; waiting senders fail with `Closed` and
// get their value back. Does nothing if the channel is already closed.
pub fn close(self: &Channel($T)) {
    const s = self.__state
    if s.closed {
        return
    }
    s.closed = true
    loop {
        const r = take_receiver(s) match {
            Some(r) => r
            None => break
        }
        r.status = WaitStatus.Closed
        r.coroutine.wake()
    }
    loop {
        const w = take_sender(s) match {
            Some(w) => w
            None => break
        }
        w.status = WaitStatus.Closed
        w.coroutine.wake()
    }
}

// Releases the channel and every value still in it.
//
// Panics if a task is still waiting on the channel.
pub fn deinit(self: move Channel($T)) {
    if self.__state.senders.is_some() or self.__state.receivers.is_some() {
        panic("channel: released while a task waits on it")
    }
    let state = move self.__state.*
    const allocator = state.allocator
    state.buffer.deinit()
    free(allocator, self.__state)
    leak(self)
}

fn add_sender(s: &ChannelState($T), w: &SendWaiter(T)) {
    s.senders match {
        None => s.senders = Some(w)
        Some(head) => {
            let at = head
            loop {
                at = at.next match {
                    Some(n) => n
                    None => break
                }
            }
            at.next = Some(w)
        }
    }
}

fn take_sender(s: &ChannelState($T)) &SendWaiter(T)? {
    const w = s.senders match {
        Some(w) => w
        None => return null
    }
    s.senders = w.next
    w.next = null
    return Some(w)
}

fn remove_sender(s: &ChannelState($T), w: &SendWaiter(T)) {
    s.senders match {
        None => {}
        Some(head) => {
            if same_sender(head, w) {
                s.senders = head.next
                return
            }
            let at = head
            loop {
                const n = at.next match {
                    Some(n) => n
                    None => return
                }
                if same_sender(n, w) {
                    at.next = n.next
                    return
                }
                at = n
            }
        }
    }
}

fn add_receiver(s: &ChannelState($T), w: &RecvWaiter(T)) {
    s.receivers match {
        None => s.receivers = Some(w)
        Some(head) => {
            let at = head
            loop {
                at = at.next match {
                    Some(n) => n
                    None => break
                }
            }
            at.next = Some(w)
        }
    }
}

fn take_receiver(s: &ChannelState($T)) &RecvWaiter(T)? {
    const r = s.receivers match {
        Some(r) => r
        None => return null
    }
    s.receivers = r.next
    r.next = null
    return Some(r)
}

fn remove_receiver(s: &ChannelState($T), w: &RecvWaiter(T)) {
    s.receivers match {
        None => {}
        Some(head) => {
            if same_receiver(head, w) {
                s.receivers = head.next
                return
            }
            let at = head
            loop {
                const n = at.next match {
                    Some(n) => n
                    None => return
                }
                if same_receiver(n, w) {
                    at.next = n.next
                    return
                }
                at = n
            }
        }
    }
}

#allow(W2004)
fn same_sender(a: &SendWaiter($T), b: &SendWaiter(T)) bool {
    return (a as usize) == (b as usize)
}

#allow(W2004)
fn same_receiver(a: &RecvWaiter($T), b: &RecvWaiter(T)) bool {
    return (a as usize) == (b as usize)
}

fn __channel_test_send_words(ch: &Channel(OwnedString)) i32 {
    for w in ["alpha", "beta", "gamma"] {
        ch.send(from_view(w)).await() ?? return 1
    }
    ch.close()
    return 0
}

fn __channel_test_total_len(ch: &Channel(OwnedString)) usize {
    let total = 0usize
    loop {
        const word = ch.recv().await() ?? break
        total = total + word.view().len
        word.deinit()
    }
    return total
}

test "owned values move through a channel without leaking" {
    let ch: Channel(OwnedString) = channel()
    const total = concurrent { s =>
        const tx = s.spawn { __channel_test_send_words(&ch) }
        const rx = s.spawn { __channel_test_total_len(&ch) }
        let _sent = tx.await()
        rx.await()
    }
    ch.deinit()
    assert_eq(total, 14usize, "alpha + beta + gamma")
}

test "releasing a channel releases the values still in it" {
    let ch: Channel(OwnedString) = channel(2)
    const sent = concurrent { s =>
        let sent = true
        ch.send(from_view("left")).await() ?? { sent = false }
        ch.send(from_view("over")).await() ?? { sent = false }
        sent
    }
    ch.deinit()
    assert_true(sent, "both fit in the buffer")
}

test "a refused try_send gives its value back to be released" {
    let ch: Channel(OwnedString) = channel()
    let refused = false
    ch.try_send(from_view("kept")) ?? { refused = true }
    ch.deinit()
    assert_true(refused, "no receiver and no room")
}
