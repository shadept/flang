//! TEST: for_over_fixed_array
//! EXIT: 18

// A fixed array iterates through `iter(&T[])` via array decay; the
// lowering must hand `iter` a real `{ptr, len}` view, not the array's
// storage pointer. Both a local and a const array, by value.

pub fn main() i32 {
    const xs = [3i32, 4i32, 5i32]
    let sum = 0i32
    for x in xs {
        sum = sum + x
    }

    const names = ["a", "bb", "ccc"]
    let chars = 0i32
    for n in names {
        chars = chars + n.len as i32
    }
    return sum + chars
}
