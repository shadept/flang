//! TEST: guard_basic
//! STDOUT: PASS

type Temp = enum {
    Reading(i32)
    Sensor
}

fn classify(t: Temp) i32 {
    return t match {
        Reading(v) if v < 0 => -1i32,
        Reading(0) => 0i32,
        Reading(v) if v > 0 and v < 100 => 1i32,
        Reading(_) => 2i32,
        Sensor => 99i32,
    }
}

fn sign(n: i32) i32 {
    return n match {
        0 => 0i32,
        _ => if n < 0 { -1i32 } else { 1i32 },
    }
}

pub fn main() i32 {
    let pass = true

    if classify(Temp.Reading(-5)) != -1 { println("FAIL: Reading(-5)"); pass = false }
    if classify(Temp.Reading(0))  != 0  { println("FAIL: Reading(0)");  pass = false }
    if classify(Temp.Reading(42)) != 1  { println("FAIL: Reading(42)"); pass = false }
    if classify(Temp.Reading(200)) != 2 { println("FAIL: Reading(200)"); pass = false }
    if classify(Temp.Sensor) != 99 { println("FAIL: Sensor"); pass = false }

    if sign(-7) != -1 { println("FAIL: sign(-7)"); pass = false }
    if sign(0)  != 0  { println("FAIL: sign(0)");  pass = false }
    if sign(7)  != 1  { println("FAIL: sign(7)");  pass = false }

    if pass { println("PASS") }
    return 0
}
