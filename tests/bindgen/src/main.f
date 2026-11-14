// Bindings generated from include/fx.h by `flang test`, called against fx_impl.c (RFC-044).

import std.option
import std.test

import vendor.fx

import bindgen_fixture.fx_impl

pub fn main() i32 {
    return 0
}

#foreign fn add(acc: i32, x: i32) i32 {
    return acc + x
}

test "an opaque handle round-trips" {
    const h = fx_open(Some("four".ptr)).unwrap()
    assert_eq(fx_count(Some(h)), 4i32, "count")
    fx_close(Some(h))
}

test "structs and unions cross by value" {
    const p = fx_add(FxPoint { x = 1, y = 2 }, FxPoint { x = 10, y = 20 })
    assert_eq(p.x, 11i32, "x")
    assert_eq(p.y, 22i32, "y")
    const v = fx_half(FxValue { f = 3.0 }, FX_REAL)
    assert_eq(v.f, 1.5f32, "float member")
    const w = fx_half(FxValue { i = 9 }, FX_INT)
    assert_eq(w.i, 4i32, "int member")
}

test "callbacks and pointer arguments" {
    const xs = [1i32, 2, 3, 4]
    assert_eq(fx_fold(Some(&xs[0]), 4, add), 10i32, "fold")
}

test "macro and enum constants" {
    assert_eq(FX_VERSION, "1.2", "string")
    assert_eq(FX_FLAG_A | FX_FLAG_B, 9u32, "unsigned flags")
    assert_eq(FX_SCALE, 2.5f32, "float")
    assert_eq(FX_REAL, 2i32, "enum")
}

test "a bit-field struct stays opaque behind its pointer" {
    assert_eq(fx_bits().is_some(), true, "pointer returned")
}
