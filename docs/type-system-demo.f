// This file demonstrates the extended type parser
// These types can now be PARSED (but not yet fully implemented)

// Simple types (already working)
pub fn simple(x: i32) i32 {
    return x
}

// Reference types (Milestone 6)
// pub fn with_reference(x: &i32) i32 {
//     return 0
// }

// Nullable types (future milestone)
// pub fn with_nullable(x: i32?) i32 {
//     return 0
// }

// Generic types (Milestone 11+)
// pub fn with_generic(list: List[i32]) i32 {
//     return 0
// }

// Complex combinations
// pub fn complex(x: &List[i32]?) i32 {
//     return 0
// }

// Complex combinations
// pub fn complex2(x: &List[i32?]) i32 {
//     return 0
// }

pub fn main() i32 {
    return simple(42)
}
