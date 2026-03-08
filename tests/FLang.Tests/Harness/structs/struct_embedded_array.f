//! TEST: struct_embedded_array
//! EXIT: 42

// Test structs with fixed-size array fields: initialization, read, write, size.

import core.rtti

type Buffer = struct {
    data: [u8; 8],
    len: usize
}

fn push(b: &Buffer, val: u8) {
    b.data[b.len] = val
    b.len = b.len + 1
}

fn sum(b: &Buffer) i32 {
    let total: i32 = 0
    for (i in 0..b.len as isize) {
        total = total + b.data[i as usize] as i32
    }
    return total
}

pub fn main() i32 {
    let buf: Buffer
    buf.len = 0

    // Write values into embedded array
    push(&buf, 10)
    push(&buf, 12)
    push(&buf, 20)

    if buf.len != 3 { return 1 }

    // Read back values
    if buf.data[0] != 10 { return 2 }
    if buf.data[1] != 12 { return 3 }
    if buf.data[2] != 20 { return 4 }

    // Sum should be 42
    if sum(&buf) != 42 { return 5 }

    // Verify struct size includes the inline array: [u8; 8] + usize = 8 + 8 = 16
    if size_of(Buffer) != 16 { return 6 }

    return 42
}
