//! TEST: sb_float_append
//! EXIT: 0

import std.string_builder

fn check_sb(sb: &StringBuilder, expected: String, msg: String) {
    const view = sb.as_view()
    if view.len != expected.len { panic(msg) }
    for i in 0..view.len {
        if view[i] != expected[i] { panic(msg) }
    }
}

pub fn main() i32 {
    let sb = string_builder()

    // Default: trim trailing zeros
    sb.append(3.14f64)
    check_sb(&sb, "3.14", "f64 3.14")
    sb.clear()

    sb.append(0.0f64)
    check_sb(&sb, "0", "f64 zero")
    sb.clear()

    sb.append(-1.5f64)
    check_sb(&sb, "-1.5", "f64 negative")
    sb.clear()

    sb.append(42.0f64)
    check_sb(&sb, "42", "f64 integer value")
    sb.clear()

    sb.append(1.0f32)
    check_sb(&sb, "1", "f32 one")
    sb.clear()

    sb.append(0.125f64)
    check_sb(&sb, "0.125", "f64 0.125")
    sb.clear()

    // Explicit precision (keeps trailing zeros)
    sb.append(3.14f64, ".2")
    check_sb(&sb, "3.14", "prec .2")
    sb.clear()

    sb.append(3.14f64, ".4")
    check_sb(&sb, "3.1400", "prec .4")
    sb.clear()

    sb.append(1.0f64, ".0")
    check_sb(&sb, "1", "prec .0")
    sb.clear()

    sb.append(1.0f64, ".3")
    check_sb(&sb, "1.000", "prec .3")
    sb.clear()

    // Rounding
    sb.append(1.456f64, ".2")
    check_sb(&sb, "1.46", "rounding .2")
    sb.clear()

    sb.append(2.999f64, ".2")
    check_sb(&sb, "3.00", "rounding up")
    sb.clear()

    sb.append(9.999f64, ".2")
    check_sb(&sb, "10.00", "rounding carry")
    sb.clear()

    // Width padding
    sb.append(3.14f64, "8.2")
    check_sb(&sb, "    3.14", "width 8 space pad")
    sb.clear()

    sb.append(3.14f64, "08.2")
    check_sb(&sb, "00003.14", "width 8 zero pad")
    sb.clear()

    sb.append(-3.14f64, "08.2")
    check_sb(&sb, "-0003.14", "neg zero pad")
    sb.clear()

    // Mixed with strings
    sb.append("x=")
    sb.append(2.5f64)
    check_sb(&sb, "x=2.5", "mixed string and float")

    sb.deinit()
    return 0
}
