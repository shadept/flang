//! TEST: cow_param_then_ref
//! EXIT: 0

// After COW triggers on a by-value param, taking &param must
// give a reference to the shadow copy, not the original.

type Data = struct {
    x: i32,
    y: i32,
    z: i32
}

fn read_ref(d: &Data) i32 {
    d.x + d.y + d.z
}

fn mutate_then_ref(d: Data) i32 {
    d.x = 100          // triggers COW
    read_ref(&d)        // must reference the shadow (100, 2, 3)
}

pub fn main() i32 {
    let original = Data { x = 1, y = 2, z = 3 }
    let result = mutate_then_ref(original)

    if original.x != 1 { return 1 }    // original unchanged
    if result != 105 { return 2 }       // 100 + 2 + 3

    return 0
}
