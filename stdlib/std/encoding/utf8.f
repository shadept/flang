import std.string
import std.test

pub fn decode_char(bytes: u8[]) (char, usize) {
    let codepoint: u32
    let length: usize

    const s = bytes[..]
    if (s.len >= 1 and s[0] <= 0x7F) { // 1-byte (0xxxxxxx)
        codepoint = s[0]
        length = 1
    } else if (s.len >= 2 and (s[0] & 0xE0) == 0xC0) { // 2-bytes (110xxxxx)
        // continuation payloads widen to u32 before shifting: shifted in u8 they truncate
        codepoint = ((s[0] as u32 & 0x1F) << 6) | (s[1] as u32 & 0x3F)
        length = 2
    } else if (s.len >= 3 and (s[0] & 0xF0) == 0xE0) { // 3-bytes (1110xxxx)
        codepoint = ((s[0] as u32 & 0x0F) << 12) | ((s[1] as u32 & 0x3F) << 6) | (s[2] as u32 & 0x3F)
        length = 3
    } else if (s.len >= 4 and (s[0] & 0xF8) == 0xF0) { // 4-bytes (11110xxx)
        codepoint = ((s[0] as u32 & 0x07) << 18) | ((s[1] as u32 & 0x3F) << 12)
            | ((s[2] as u32 & 0x3F) << 6) | (s[3] as u32 & 0x3F)
        length = 4
    } else {
        codepoint = 0xFFFD
        length = 1
    }

    return (codepoint as char, length)
}

pub fn encode_char(codepoint: char, dest: u8[]) usize {
    let length = 0usize

    if (codepoint <= 0x7F) {
        dest[0] = codepoint as u8
        length = 1
    } else if (codepoint <= 0x7FF) {
        dest[0] = 0xC0 | ((codepoint >> 6) as u8)
        dest[1] = 0x80 | ((codepoint & 0x3F) as u8)
        length = 2
    } else if (codepoint <= 0xFFFF) {
        dest[0] = 0xE0 | ((codepoint >> 12) as u8)
        dest[1] = 0x80 | ((codepoint >> 6 & 0x3F) as u8)
        dest[2] = 0x80 | ((codepoint & 0x3F) as u8)
        length = 3
    } else if (codepoint <= 0x10FFFF) {
        dest[0] = 0xF0 | ((codepoint >> 18) as u8)
        dest[1] = 0x80 | ((codepoint >> 12 & 0x3F) as u8)
        dest[2] = 0x80 | ((codepoint >> 6 & 0x3F) as u8)
        dest[3] = 0x80 | ((codepoint & 0x3F) as u8)
        length = 4
    } else {
        dest[0] = 0xEF
        dest[1] = 0xBF
        dest[2] = 0xBD
        length = 3
    }

    return length
}

// Tests

test "decode covers all four sequence widths" {
    // a (1 byte), é (2), € (3), 😀 (4)
    const text = "aé€😀"
    const bytes = text.as_raw_bytes()

    const a = decode_char(bytes[0..bytes.len])
    assert_eq(a.0 as u32, 97, "1-byte a")
    assert_eq(a.1, 1, "width 1")

    const e2 = decode_char(bytes[1..bytes.len])
    assert_eq(e2.0 as u32, 0xE9, "2-byte e-acute")
    assert_eq(e2.1, 2, "width 2")

    const e3 = decode_char(bytes[3..bytes.len])
    assert_eq(e3.0 as u32, 0x20AC, "3-byte euro sign")
    assert_eq(e3.1, 3, "width 3")

    const e4 = decode_char(bytes[6..bytes.len])
    assert_eq(e4.0 as u32, 0x1F600, "4-byte emoji")
    assert_eq(e4.1, 4, "width 4")
}

test "encode/decode round-trip" {
    let buf = [0u8; 4]
    const cps = [97u32, 0xE9, 0x20AC, 0x1F600]
    for cp in cps {
        const n = encode_char(cp as char, buf as u8[])
        const back = decode_char(buf[0..n])
        assert_eq(back.0 as u32, cp, "codepoint survives the round trip")
        assert_eq(back.1, n, "width agrees")
    }
}

test "invalid lead byte yields the replacement char, width 1" {
    const bad: [u8; 2] = [0xFF, 0x41]
    const d = decode_char(bad as u8[])
    assert_eq(d.0 as u32, 0xFFFD, "replacement char")
    assert_eq(d.1, 1, "resynchronizes on the next byte")
}
