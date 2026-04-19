//! TEST: char_literal_pattern
//! STDOUT: PASS

type Token = enum {
    Char(u8)
    None
}

pub fn main() i32 {
    let c: u8 = 65

    // char literal pattern decays to u8
    let r = c match {
        'A' => 1i32,
        'B' => 2i32,
        _ => 0i32
    }
    if r != 1 {
        println("FAIL top")
        return 1
    }

    // char literal pattern inside enum variant
    let tok = Token.Char('l')
    let r2 = tok match {
        Char('l') => 10i32,
        Char(_) => 20i32,
        None => 30i32
    }
    if r2 != 10 {
        println("FAIL sub")
        return 1
    }

    println("PASS")
    return 0
}
