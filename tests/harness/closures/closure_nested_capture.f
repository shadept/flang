//! TEST: closure_nested_capture
//! EXIT: 21

// A closure inside a closure reaches a name from further out: the inner env takes the outer env's
// reference.
pub fn main() i32 {
    let xa: [i32; 2] = [1, 2]
    let ya: [i32; 3] = [1, 2, 4]
    let xs: i32[] = xa
    let ys: i32[] = ya
    let total = 0
    xs.each(fn(x: i32) {
        ys.each(fn(y: i32) {
            total = total + x * y
        })
    })
    return total
}
