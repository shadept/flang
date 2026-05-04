//! TEST: tuple_pattern
//! STDOUT: PASS

fn classify(p: (i32, bool)) i32 {
    return p match {
        (0, _) => 0i32,
        (n, true) => n,
        (n, false) => -n,
    }
}

fn corner(p: (i32, i32)) i32 {
    return p match {
        (0, 0) => 1i32,
        (_, 0) => 2i32,
        (0, _) => 3i32,
        (_, _) => 4i32,
    }
}

pub fn main() i32 {
    let pass = true

    if classify((0, true))  != 0  { println("FAIL: (0,true)");  pass = false }
    if classify((5, true))  != 5  { println("FAIL: (5,true)");  pass = false }
    if classify((7, false)) != -7 { println("FAIL: (7,false)"); pass = false }

    if corner((0, 0)) != 1 { println("FAIL: (0,0)"); pass = false }
    if corner((3, 0)) != 2 { println("FAIL: (3,0)"); pass = false }
    if corner((0, 4)) != 3 { println("FAIL: (0,4)"); pass = false }
    if corner((1, 1)) != 4 { println("FAIL: (1,1)"); pass = false }

    if pass { println("PASS") }
    return 0
}
