
pub fn lower(c: char) char {
    const a = 'a'
    const A = 'A'
    const Z = 'Z'
    if (c >= A and c <= Z) {
        c + (a - A)
    } else {
        c
    }
}

pub fn upper(c: char) char {
    const a = 'a'
    const z = 'z'
    const A = 'A'
    if (c >= a and c <= z) {
        c - (a - A)
    } else {
        c
    }
}
