//! TEST: float_div_by_zero_constant
//! EXIT: 15

// A division by a literal zero yields the IEEE 754 result, and the C it compiles to builds.
pub fn main() i32 {
    const pos: f64 = 1.0f64 / 0.0f64
    const neg: f64 = -1.0f64 / 0.0f64
    const flipped: f64 = 1.0f64 / -0.0f64
    const nan: f64 = 0.0f64 / 0.0f64
    let r: i32 = 0
    if pos > 1.0e308f64 {
        r = r + 1
    }
    if neg < -1.0e308f64 {
        r = r + 2
    }
    if flipped < -1.0e308f64 {
        r = r + 4
    }
    if nan != nan {
        r = r + 8
    }
    return r
}
