//! TEST: nested_type_cross_module
//! EXIT: 126

// RFC-046: a `pub` type nested in a `pub` type is reached from another module through its owner.
import _nested_lib

pub fn main() i32 {
    const a: Pub.Open = Pub.Open { x = 1 }
    const m: Pub.Mode = Pub.Mode.Off(5)
    const on: Pub.Mode = Pub.Mode.On
    const c: Gen(i32).Cell(u8) = Gen(i32).Cell(u8) { t = 10, u = 2 }
    const name: String = type_info(Gen(i32).Cell(u8)).name
    const mv: i32 = m match {
        On => 0
        Off(v) => v
    }
    const ov: i32 = on match {
        On => 100
        Off(v) => v
    }
    return a.x + mv + c.t + (c.u as i32) + (name.len as i32) + ov
}
