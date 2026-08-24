//! TEST: tuple_in_variant_payload
//! STDOUT: PASS

// A tuple sub-pattern inside a variant payload (`Ok((v, n))`) binds both
// elements. Regression: the checker recorded a node type only for VARIABLE
// patterns, so lowering read the tuple sub-pattern's type off its node,
// got the `i32` fallback, refused to see a tuple, and silently dropped
// both bindings - surfacing later as "unbound name read".

type Parsed = enum {
    Ok((i32, usize))
    Err(i32)
}

fn parse(good: bool) Parsed {
    if good { return Parsed.Ok((7, 3 as usize)) }
    return Parsed.Err(1)
}

pub fn main() i32 {
    let sum = 0
    parse(true) match {
        Ok((value, consumed)) => { sum = value + (consumed as i32) }
        Err(_) => { sum = -1 }
    }
    if sum != 10 { println("FAIL: expected 10"); return 1 }

    parse(false) match {
        Ok((_, _)) => { sum = -1 }
        Err(code) => { sum = code }
    }
    if sum != 1 { println("FAIL: expected 1"); return 1 }

    println("PASS")
    return 0
}
