//! TEST: iterator_custom_counter
//! EXIT: 33

struct Counter {
    start: i32
    count: i32
}

struct CounterState {
    current: i32
    remaining: i32
}

fn iter(c: &Counter) CounterState {
    return .{ current = c.start, remaining = c.count }
}

fn next(state: &CounterState) i32? {
    if (state.remaining <= 0) {
        return null
    }
    let val = state.current
    state.current = state.current + 1
    state.remaining = state.remaining - 1
    return val
}

pub fn main() i32 {
    let c: Counter = .{ start = 10, count = 3 }
    let sum: i32 = 0
    for (x in c) {
        sum = sum + x
    }
    return sum  // 10 + 11 + 12 = 33
}
