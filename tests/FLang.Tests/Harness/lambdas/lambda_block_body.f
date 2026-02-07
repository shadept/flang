//! TEST: lambda_block_body
//! EXIT: 42

// Test lambda with multi-statement block body

pub fn main() i32 {
    let compute = fn(x: i32, y: i32) i32 {
        let sum = x + y
        let doubled = sum * 2
        return doubled
    }
    return compute(10, 11)
}
