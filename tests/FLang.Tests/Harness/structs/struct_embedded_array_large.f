//! TEST: struct_embedded_array_large
//! EXIT: 42

// Test large structs with multiple embedded arrays and address-of element.

import core.rtti

type Decoder = struct {
    buf: [u8; 64],
    stack: [u8; 16],
    buf_len: usize,
    stack_len: usize
}

fn write_buf(d: &Decoder, val: u8) {
    d.buf[d.buf_len] = val
    d.buf_len = d.buf_len + 1
}

fn push_stack(d: &Decoder, val: u8) {
    d.stack[d.stack_len] = val
    d.stack_len = d.stack_len + 1
}

fn buf_sum(d: &Decoder) i32 {
    let total: i32 = 0
    for (i in 0..d.buf_len as isize) {
        total = total + d.buf[i as usize] as i32
    }
    return total
}

pub fn main() i32 {
    let d: Decoder
    d.buf_len = 0
    d.stack_len = 0

    // Fill buf with some values
    write_buf(&d, 1)
    write_buf(&d, 2)
    write_buf(&d, 3)
    write_buf(&d, 4)

    // Fill stack
    push_stack(&d, 10)
    push_stack(&d, 20)

    if d.buf_len != 4 { return 1 }
    if d.stack_len != 2 { return 2 }

    // Verify buf contents
    if d.buf[0] != 1 { return 3 }
    if d.buf[3] != 4 { return 4 }

    // Verify stack contents
    if d.stack[0] != 10 { return 5 }
    if d.stack[1] != 20 { return 6 }

    // buf sum = 1+2+3+4 = 10
    if buf_sum(&d) != 10 { return 7 }

    // Address-of element in embedded array
    const ptr: &u8 = &d.buf[2]
    if ptr.* != 3 { return 8 }

    // Verify struct size: [u8; 64] + [u8; 16] + usize + usize = 64 + 16 + 8 + 8 = 96
    if size_of(Decoder) != 96 { return 9 }

    return 42
}
