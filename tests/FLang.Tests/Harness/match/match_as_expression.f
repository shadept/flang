//! TEST: match_as_expression
//! EXIT: 49

enum Result {
    Ok(i32)
    Err(i32)
}

pub fn main() i32 {
    let r1 = Result.Ok(10)
    let r2 = Result.Err(100)
    
    // Match as expression in return statement (direct)
    let x = get_value(r1)
    
    // Match as expression in arithmetic operation
    let y = 5 + (r1 match {
        Ok(v) => v,
        Err(_) => 0
    })
    
    // Match as nested expression (function argument)
    let z = double(r2 match {
        Ok(v) => v,
        Err(_) => 7
    })
    
    // Match in conditional
    let w: i32 = if (r1 match { Ok(_) => true, Err(_) => false }) {
        10
    } else {
        0
    }
    
    return x + y + z + w
}

fn get_value(r: Result) i32 {
    return r match {
        Ok(v) => v,
        Err(_) => 0
    }
}

fn double(x: i32) i32 {
    return x + x
}

