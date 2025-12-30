//! TEST: match_variable_binding
//! EXIT: 35

enum Data {
    Single(i32)
    Pair(i32, i32)
    Triple(i32, i32, i32)
}

pub fn main() i32 {
    let d1: Data = Data.Single(10)
    let d2: Data = Data.Pair(5, 15)
    let d3: Data = Data.Triple(1, 2, 2)
    
    let r1 = d1 match {
        Single(x) => x,
        Pair(x, y) => x + y,
        Triple(x, y, z) => x + y + z
    }
    
    let r2 = d2 match {
        Single(x) => x,
        Pair(a, b) => a + b,
        Triple(x, y, z) => x + y + z
    }
    
    let r3 = d3 match {
        Single(x) => x,
        Pair(x, y) => x + y,
        Triple(x, y, z) => x + y + z
    }
    
    return r1 + r2 + r3
}

