//! TEST: derive_hash
//! EXIT: 0

import std.derive

type Vec2 = struct {
    x: i32
    y: i32
}

#derive(Vec2, hash)

pub fn main() i32 {
    let a = Vec2 { x = 10, y = 20 }
    let b = Vec2 { x = 10, y = 20 }
    let c = Vec2 { x = 99, y = 20 }

    // Same values must produce same hash
    if hash(a) != hash(b) { return 1 }

    // Different values should produce different hash
    if hash(a) == hash(c) { return 2 }

    // Hash should be non-zero
    if hash(a) == 0 { return 3 }

    return 0
}
