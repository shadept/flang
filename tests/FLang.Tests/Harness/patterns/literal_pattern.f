//! TEST: literal_pattern
//! STDOUT: PASS

type Token = enum {
    Char(u8)
    Num(i32)
    None
}

fn test_integer_literal_pattern() bool {
    let x: i32 = 42
    let result = x match {
        42 => true,
        _ => false
    }
    return result
}

fn test_byte_literal_pattern() bool {
    let c: u8 = 65
    let result = c match {
        65 => 1i32,
        66 => 2i32,
        _ => 0i32
    }
    return result == 1
}

fn test_bool_literal_pattern() bool {
    let b = true
    let result = b match {
        true => 10i32,
        false => 20i32
    }
    return result == 10
}

fn test_enum_literal_subpattern() bool {
    let tok = Token.Num(42)
    let result = tok match {
        Num(42) => true,
        Num(_) => false,
        _ => false
    }
    return result
}

fn test_enum_byte_subpattern() bool {
    let tok = Token.Char(b'l')
    let result = tok match {
        Char(b'l') => 1i32,
        Char(b'w') => 2i32,
        Char(b'c') => 3i32,
        _ => 0i32
    }
    return result == 1
}

fn test_enum_byte_subpattern_fallthrough() bool {
    let tok = Token.Char(b'w')
    let result = tok match {
        Char(b'l') => 1i32,
        Char(b'w') => 2i32,
        Char(b'c') => 3i32,
        _ => 0i32
    }
    return result == 2
}

fn test_enum_byte_subpattern_wildcard() bool {
    let tok = Token.Char(b'x')
    let result = tok match {
        Char(b'l') => 1i32,
        Char(b'w') => 2i32,
        _ => 0i32
    }
    return result == 0
}

fn test_multiple_integer_literals() bool {
    let x: i32 = 3
    let result = x match {
        1 => 10i32,
        2 => 20i32,
        3 => 30i32,
        _ => 0i32
    }
    return result == 30
}

fn test_enum_none_with_literal() bool {
    let tok = Token.None
    let result = tok match {
        Char(b'a') => 1i32,
        Num(0) => 2i32,
        None => 3i32,
        _ => 0i32
    }
    return result == 3
}

pub fn main() i32 {
    let pass = true

    if !test_integer_literal_pattern() {
        println("FAIL: test_integer_literal_pattern")
        pass = false
    }
    if !test_byte_literal_pattern() {
        println("FAIL: test_byte_literal_pattern")
        pass = false
    }
    if !test_bool_literal_pattern() {
        println("FAIL: test_bool_literal_pattern")
        pass = false
    }
    if !test_enum_literal_subpattern() {
        println("FAIL: test_enum_literal_subpattern")
        pass = false
    }
    if !test_enum_byte_subpattern() {
        println("FAIL: test_enum_byte_subpattern")
        pass = false
    }
    if !test_enum_byte_subpattern_fallthrough() {
        println("FAIL: test_enum_byte_subpattern_fallthrough")
        pass = false
    }
    if !test_enum_byte_subpattern_wildcard() {
        println("FAIL: test_enum_byte_subpattern_wildcard")
        pass = false
    }
    if !test_multiple_integer_literals() {
        println("FAIL: test_multiple_integer_literals")
        pass = false
    }
    if !test_enum_none_with_literal() {
        println("FAIL: test_enum_none_with_literal")
        pass = false
    }

    if pass {
        println("PASS")
    }

    return 0
}
