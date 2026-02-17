//! TEST: cow_field_then_read
//! EXIT: 0

// After copy-on-write triggers, all subsequent reads and writes
// must use the shadow copy, not the original by-ref pointer.

type Config = struct {
    width: i32,
    height: i32,
    depth: i32
}

fn modify_all(c: Config) Config {
    // First write triggers COW shadow
    c.width = c.width * 2

    // Subsequent reads must come from shadow (which has the old data for other fields)
    let h = c.height
    if h != 480 { return Config { width = -1, height = -1, depth = -1 } }

    // Subsequent writes go to shadow
    c.height = h * 2
    c.depth = c.depth + 1

    c
}

pub fn main() i32 {
    let original = Config { width = 640, height = 480, depth = 24 }
    let modified = modify_all(original)

    // Original unchanged
    if original.width != 640 { return 1 }
    if original.height != 480 { return 2 }
    if original.depth != 24 { return 3 }

    // Modified reflects all changes
    if modified.width != 1280 { return 4 }
    if modified.height != 960 { return 5 }
    if modified.depth != 25 { return 6 }

    return 0
}
