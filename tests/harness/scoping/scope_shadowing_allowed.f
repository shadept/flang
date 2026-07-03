//! TEST: scope_shadowing_allowed
//! EXPECT: 20
//! EXPECT: 10

const X: i32 = 10

pub fn main() i32 {
    // Inner scope shadows global — this is allowed
    let X: i32 = 20
    println(X)
    if true {
        // Nested scope shadows outer local — also allowed
        let X: i32 = 10
        println(X)
    }
    return 0
}
