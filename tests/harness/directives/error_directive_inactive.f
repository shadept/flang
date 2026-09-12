//! TEST: directives_error_directive_inactive
//! EXIT: 0

// A `#error` in the inactive branch of a specialization is never evaluated.

fn spill(src: $T[], dest: T[]) usize {
    #if !type_info(T).copyable {
        #error("needs copyable elements")
    }
    return src.len
}

pub fn main() i32 {
    let a: i32[] = [1, 2]
    let b: i32[] = [3, 4]
    return (spill(a, b) - 2) as i32
}
