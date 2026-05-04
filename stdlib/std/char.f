import std.test

pub fn lower(c: char) char {
    return c match {
        'A'..='Z' => c + ('a' - 'A'),
        _         => c,
    }
}

pub fn upper(c: char) char {
    return c match {
        'a'..='z' => c - ('a' - 'A'),
        _         => c,
    }
}

pub fn is_digit(c: u8) bool {
    return c match {
        '0'..='9' => true,
        _         => false,
    }
}

pub fn is_alpha(c: u8) bool {
    return c match {
        'A'..='Z' => true,
        'a'..='z' => true,
        _         => false,
    }
}

pub fn is_alnum(c: u8) bool {
    return c match {
        '0'..='9' => true,
        'A'..='Z' => true,
        'a'..='z' => true,
        _         => false,
    }
}

pub fn is_whitespace(c: u8) bool {
    return c match {
        ' ' | '\t' | '\n' | '\r' => true,
        _                        => false,
    }
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
