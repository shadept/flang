//! TEST: range_pattern
//! STDOUT: PASS

fn bucket(n: i32) i32 {
    return n match {
        ..0     => -1i32,
        0       => 0i32,
        1..10   => 1i32,
        10..100 => 2i32,
        100..   => 3i32,
    }
}

fn ascii_class(c: u8) i32 {
    return c match {
        b'0'..=b'9' => 1i32,
        b'A'..=b'Z' => 2i32,
        b'a'..=b'z' => 3i32,
        _           => 0i32,
    }
}

pub fn main() i32 {
    let pass = true

    if bucket(-5)  != -1 { println("FAIL: bucket(-5)");  pass = false }
    if bucket(0)   != 0  { println("FAIL: bucket(0)");   pass = false }
    if bucket(5)   != 1  { println("FAIL: bucket(5)");   pass = false }
    if bucket(50)  != 2  { println("FAIL: bucket(50)");  pass = false }
    if bucket(500) != 3  { println("FAIL: bucket(500)"); pass = false }

    if ascii_class(b'5') != 1 { println("FAIL: '5'"); pass = false }
    if ascii_class(b'M') != 2 { println("FAIL: 'M'"); pass = false }
    if ascii_class(b'q') != 3 { println("FAIL: 'q'"); pass = false }
    if ascii_class(b'!') != 0 { println("FAIL: '!'"); pass = false }

    if pass { println("PASS") }
    return 0
}
