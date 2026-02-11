//! TEST: large_struct_return_slot
//! EXIT: 0

// Large struct returns use caller-provided hidden return slot.
// Tests that return values don't corrupt each other.

struct Rect {
    x: i32,
    y: i32,
    w: i32,
    h: i32
}

fn make_rect(x: i32, y: i32, w: i32, h: i32) Rect {
    Rect { x = x, y = y, w = w, h = h }
}

fn area(r: Rect) i32 {
    r.w * r.h
}

fn translate(r: Rect, dx: i32, dy: i32) Rect {
    make_rect(r.x + dx, r.y + dy, r.w, r.h)
}

pub fn main() i32 {
    let a = make_rect(0, 0, 10, 20)
    let b = make_rect(5, 5, 3, 4)
    let c = translate(a, 100, 200)

    if area(a) != 200 { return 1 }
    if area(b) != 12 { return 2 }
    if c.x != 100 { return 3 }
    if c.y != 200 { return 4 }
    if c.w != 10 { return 5 }

    // Nested return slots: translate returns into slot, area reads from it
    if area(translate(b, 1, 1)) != 12 { return 6 }

    return 0
}
