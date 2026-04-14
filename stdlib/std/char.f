import std.test

pub fn lower(c: char) char {
    const a = 'a'
    const A = 'A'
    const Z = 'Z'
    if c >= A and c <= Z {
        c + (a - A)
    } else {
        c
    }
}

pub fn upper(c: char) char {
    const a = 'a'
    const z = 'z'
    const A = 'A'
    if c >= a and c <= z {
        c - (a - A)
    } else {
        c
    }
}

pub fn is_digit(c: u8) bool {
    return c >= b'0' and c <= b'9'
}

pub fn is_alpha(c: u8) bool {
    return (c >= b'A' and c <= b'Z') or (c >= b'a' and c <= b'z')
}

pub fn is_alnum(c: u8) bool {
    return is_digit(c) or is_alpha(c)
}

pub fn is_whitespace(c: u8) bool {
    return c == b' ' or c == b'\t' or c == b'\n' or c == b'\r'
}

test "is_digit" {
    assert_true(is_digit(b'0'), "0 is digit")
    assert_true(is_digit(b'9'), "9 is digit")
    assert_true(!is_digit(b'a'), "a is not digit")
    assert_true(!is_digit(b' '), "space is not digit")
}

test "is_alpha" {
    assert_true(is_alpha(b'a'), "a is alpha")
    assert_true(is_alpha(b'Z'), "Z is alpha")
    assert_true(!is_alpha(b'0'), "0 is not alpha")
    assert_true(!is_alpha(b' '), "space is not alpha")
}

test "is_alnum" {
    assert_true(is_alnum(b'a'), "a is alnum")
    assert_true(is_alnum(b'5'), "5 is alnum")
    assert_true(!is_alnum(b' '), "space is not alnum")
}

test "is_whitespace" {
    assert_true(is_whitespace(b' '), "space is whitespace")
    assert_true(is_whitespace(b'\t'), "tab is whitespace")
    assert_true(is_whitespace(b'\n'), "newline is whitespace")
    assert_true(!is_whitespace(b'a'), "a is not whitespace")
}
