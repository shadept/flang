//! TEST: char_unicode_escape
//! EXIT: 0
pub fn main() i32 {
    // Basic unicode escape
    let a: char = '\u41'     // 'A' = U+0041
    if (a != 65u32 as char) { return 1 }

    // Multi-byte codepoint
    let smiley: char = '\u1F600'
    if (smiley != 128512u32 as char) { return 2 }

    // Euro sign
    let euro: char = '\u20AC'
    if (euro != 8364u32 as char) { return 3 }

    return 0
}
