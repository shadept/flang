//! TEST: variable_shadowing
//! EXIT: 0

pub fn main() i32 {
    // Test basic shadowing: second x replaces first
    let x: i32 = 10
    let x: i32 = 20
    if (x != 20) {
        return 1
    }

    // Test shadowing with self-reference in initializer
    let y: i32 = 5
    let y: i32 = y + 1
    if (y != 6) {
        return 2
    }

    // Test multiple shadows
    let z: i32 = 1
    let z: i32 = z + z
    let z: i32 = z + z
    if (z != 4) {
        return 3
    }

    return 0
}
