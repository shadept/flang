import std.test

// ASCII classification. Written as explicit bound checks rather than range and or patterns: those
// are the only two uses of either form in the whole self-host corpus, and the self-hosted front end
// does not parse them yet (docs/known-issues.md). The comparisons are exactly equivalent and read
// no worse for predicates like these.

pub fn lower(c: char) char {
    if c >= 'A' and c <= 'Z' {
        return c + ('a' - 'A')
    }
    return c
}

pub fn upper(c: char) char {
    if c >= 'a' and c <= 'z' {
        return c - ('a' - 'A')
    }
    return c
}

pub fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9'
}

pub fn is_alpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')
}

pub fn is_alnum(c: u8) bool {
    return is_digit(c) or is_alpha(c)
}

pub fn is_whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r'
}

test "is_digit" {
    assert_true(is_digit('0'), "0 is digit")
    assert_true(is_digit('9'), "9 is digit")
    assert_true(!is_digit('a'), "a is not digit")
    assert_true(!is_digit(' '), "space is not digit")
}

test "is_alpha" {
    assert_true(is_alpha('a'), "a is alpha")
    assert_true(is_alpha('Z'), "Z is alpha")
    assert_true(!is_alpha('0'), "0 is not alpha")
    assert_true(!is_alpha(' '), "space is not alpha")
}

test "is_alnum" {
    assert_true(is_alnum('a'), "a is alnum")
    assert_true(is_alnum('5'), "5 is alnum")
    assert_true(!is_alnum(' '), "space is not alnum")
}

test "is_whitespace" {
    assert_true(is_whitespace(' '), "space is whitespace")
    assert_true(is_whitespace('\t'), "tab is whitespace")
    assert_true(is_whitespace('\n'), "newline is whitespace")
    assert_true(!is_whitespace('a'), "a is not whitespace")
}
