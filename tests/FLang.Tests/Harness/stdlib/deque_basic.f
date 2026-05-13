//! TEST: deque_basic
//! EXIT: 0

import std.deque
import std.option

pub fn main() i32 {
    let dq: Deque(i32) = deque(0)
    defer dq.deinit()

    if !dq.is_empty() { return 1 }
    if dq.pop_front().is_some() { return 2 }
    if dq.pop_back().is_some() { return 3 }

    // Queue: push_back / pop_front yields FIFO.
    dq.push_back(1i32)
    dq.push_back(2i32)
    dq.push_back(3i32)
    if dq.len != 3 { return 4 }
    if dq.peek_front().unwrap_or(0i32) != 1i32 { return 5 }
    if dq.peek_back().unwrap_or(0i32) != 3i32 { return 6 }
    if dq.pop_front().unwrap_or(0i32) != 1i32 { return 7 }
    if dq.pop_front().unwrap_or(0i32) != 2i32 { return 8 }
    if dq.pop_front().unwrap_or(0i32) != 3i32 { return 9 }
    if !dq.is_empty() { return 10 }

    // Stack: push_back / pop_back yields LIFO.
    dq.push_back(10i32)
    dq.push_back(20i32)
    dq.push_back(30i32)
    if dq.pop_back().unwrap_or(0i32) != 30i32 { return 11 }
    if dq.pop_back().unwrap_or(0i32) != 20i32 { return 12 }
    if dq.pop_back().unwrap_or(0i32) != 10i32 { return 13 }

    // push_front prepends.
    dq.push_front(2i32)
    dq.push_front(1i32)
    dq.push_back(3i32)
    if dq.pop_front().unwrap_or(0i32) != 1i32 { return 14 }
    if dq.pop_front().unwrap_or(0i32) != 2i32 { return 15 }
    if dq.pop_front().unwrap_or(0i32) != 3i32 { return 16 }

    // Force a wrap-around: keep push_back / pop_front cycling so head
    // walks past the buffer end before triggering growth.
    let dq2: Deque(i32) = deque(4)
    defer dq2.deinit()
    for i in 0usize..16usize {
        dq2.push_back(i as i32)
        if dq2.len > 2 {
            let popped = dq2.pop_front()
            if popped.is_none() { return 17 }
        }
    }
    // Drain and check contents in order.
    let expected = 14i32
    loop {
        let v_opt = dq2.pop_front()
        if v_opt.is_none() { break }
        if v_opt.unwrap() != expected { return 18 }
        expected = expected + 1i32
    }

    return 0
}
