//! TEST: struct_pattern
//! STDOUT: PASS

type Point = struct {
    x: i32
    y: i32
}

type Named = struct {
    id: i32
    name: String
    active: bool
}

fn classify(p: Point) i32 {
    return p match {
        Point { x = 0, y = 0 } => 0i32,
        Point { x = 0, y } => y,
        Point { x, y = 0 } => x,
        Point { x, y } => x + y,
    }
}

fn id_only(n: Named) i32 {
    // Use `..` to ignore other fields.
    return n match {
        Named { id, .. } => id,
    }
}

fn id_when_active(n: Named) i32 {
    return n match {
        Named { id, active = true, .. } => id,
        Named { .. } => -1i32,
    }
}

pub fn main() i32 {
    let pass = true

    let p00 = Point { x = 0, y = 0 }
    let p05 = Point { x = 0, y = 5 }
    let p70 = Point { x = 7, y = 0 }
    let p34 = Point { x = 3, y = 4 }
    if classify(p00) != 0 { println("FAIL: 0,0"); pass = false }
    if classify(p05) != 5 { println("FAIL: 0,5"); pass = false }
    if classify(p70) != 7 { println("FAIL: 7,0"); pass = false }
    if classify(p34) != 7 { println("FAIL: 3,4"); pass = false }

    let alice = Named { id = 42, name = "alice", active = true }
    let bob = Named { id = 7, name = "bob", active = false }

    if id_only(alice) != 42 { println("FAIL: id_only(alice)"); pass = false }
    if id_when_active(alice) != 42 { println("FAIL: alice active"); pass = false }
    if id_when_active(bob) != -1 { println("FAIL: bob inactive"); pass = false }

    if pass { println("PASS") }
    return 0
}
