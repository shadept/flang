//! TEST: struct_embedded_array_nested
//! EXIT: 42

// Test struct containing a nested struct (without embedded arrays in the inner)
// and an embedded array at the outer level.

import core.rtti

type Header = struct {
    tag: i32,
    version: i32
}

type Packet = struct {
    header: Header,
    payload: [u8; 8],
    payload_len: usize
}

fn push_byte(p: &Packet, val: u8) {
    p.payload[p.payload_len] = val
    p.payload_len = p.payload_len + 1
}

pub fn main() i32 {
    let p: Packet
    p.header.tag = 1
    p.header.version = 2
    p.payload_len = 0

    push_byte(&p, 10)
    push_byte(&p, 20)
    push_byte(&p, 12)

    if p.header.tag != 1 { return 1 }
    if p.header.version != 2 { return 2 }
    if p.payload_len != 3 { return 3 }
    if p.payload[0] != 10 { return 4 }
    if p.payload[1] != 20 { return 5 }
    if p.payload[2] != 12 { return 6 }

    // 10 + 20 + 12 = 42
    let total: i32 = p.payload[0] as i32 + p.payload[1] as i32 + p.payload[2] as i32
    if total != 42 { return 7 }

    // Verify sizes: Header = 2*i32 = 8, Packet = Header(8) + [u8;8](8) + usize(8) = 24
    if size_of(Header) != 8 { return 8 }
    if size_of(Packet) != 24 { return 9 }

    return 42
}
