pub fn abs(x: $T) T {
    if (x < 0) {
        return -x
    }
    return x
}

pub fn clamp(x: i32, lower: i32, upper: i32) i32 {
    return max(lower, min(x, upper))
}

pub fn max(a: $T, b: T) T {
    if (a < b) {
        return b
    }
    return a
}

pub fn min(a: $T, b: T) T {
    if (a < b) {
        return a
    }
    return b
}
