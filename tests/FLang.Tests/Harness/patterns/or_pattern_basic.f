//! TEST: or_pattern_basic
//! STDOUT: PASS

type Color = enum {
    Red
    Green
    Blue
    Yellow
}

fn primary(c: Color) bool {
    return c match {
        Red | Green | Blue => true,
        Yellow => false,
    }
}

fn classify(n: i32) i32 {
    return n match {
        1 | 2 | 3 => 1i32,
        4 | 5 | 6 => 2i32,
        _ => 0i32,
    }
}

pub fn main() i32 {
    let pass = true

    if !primary(Color.Red) { println("FAIL: Red"); pass = false }
    if !primary(Color.Green) { println("FAIL: Green"); pass = false }
    if !primary(Color.Blue) { println("FAIL: Blue"); pass = false }
    if primary(Color.Yellow) { println("FAIL: Yellow"); pass = false }

    if classify(1) != 1 { println("FAIL: classify(1)"); pass = false }
    if classify(3) != 1 { println("FAIL: classify(3)"); pass = false }
    if classify(5) != 2 { println("FAIL: classify(5)"); pass = false }
    if classify(99) != 0 { println("FAIL: classify(99)"); pass = false }

    if pass { println("PASS") }
    return 0
}
