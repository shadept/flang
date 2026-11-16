//! TEST: local_type_basic
//! EXIT: 42

// RFC-046: a function body declares a struct, an enum and an alias; each is used above its
// declaration, and bare variants of the local enum resolve.

pub fn main() i32 {
    const e: Event = Accepted(40)
    const p = Point { x = 1, y = 1 }

    type Event = enum {
        Accepted(i32)
        Stop
    }
    type Point = struct {
        x: Count
        y: Count
    }
    type Count = i32

    const n: Count = e match {
        Accepted(v) => v
        Stop => 0
    }
    return n + p.x + p.y
}
