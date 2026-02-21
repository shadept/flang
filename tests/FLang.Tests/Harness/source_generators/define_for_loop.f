//! TEST: define_for_loop
//! EXIT: 0

// Test #for loop over struct fields to generate field-by-field equality.

#define(derive_eq, T: Type) {
    fn op_eq(a: #(T.name), b: #(T.name)) bool {
        #for field in type_of(T.name).fields {
            if a.#(field.name) != b.#(field.name) { return false }
        }
        return true
    }
}

type Vec2 = struct {
    x: i32
    y: i32
}

#derive_eq(Vec2)

pub fn main() i32 {
    let a = Vec2 { x = 10, y = 20 }
    let b = Vec2 { x = 10, y = 20 }
    let c = Vec2 { x = 10, y = 99 }

    if a != b { return 1 }
    if a == c { return 2 }

    return 0
}
