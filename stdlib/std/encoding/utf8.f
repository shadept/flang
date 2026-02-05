pub fn decode_char(bytes: u8[]) (char, usize) {
    let codepoint: u32
    let length: usize

    const s = bytes[..]
    if (s.len >= 1 and s[0] <= 0x7F) { // 1-byte (0xxxxxxx)
        codepoint = s[0]
        length = 1
    } else if (s.len >= 2 and (s[0] & 0xE0) == 0xC0) { // 2-bytes (110xxxxx)
        codepoint = ((s[0] & 0x1F) << 6) | (s[1] & 0x3F)
        length = 2
    } else if (s.len >= 3 and (s[0] & 0xF0) == 0xE0) { // 3-bytes (1110xxxx)
        codepoint = ((s[0] & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F)
        length = 3
    } else if (s.len >= 4 and (s[0] & 0xF8) == 0xF0) { // 4-bytes (11110xxx)
        codepoint = ((s[0] & 0x07) << 18) | ((s[1] & 0x3F) << 12) | ((s[2] & 0x3F) << 6) | (s[3] & 0x3F)
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
