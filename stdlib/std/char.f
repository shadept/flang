
pub fn lower(c: u8) u8 {
    const a = 97 // 'a'
    const A = 65 // 'A'
    const Z = 90 // 'Z'
    if (c >= A and c <= Z) {
        c + (a - A)
    } else {
        c
    }
}

pub fn upper(c: u8) u8 {
    const a = 97 // 'a'
    const z = 122 // 'z'
    const A = 65 // 'A'
    if (c >= a and c <= z) {
        c - (a - A)
    } else {
        c
    }
}
