//! TEST: op_deref_overload_positions
//! EXIT: 29

// Explicit and implicit deref must pick the overload for the type they
// actually produce, in every position:
//   b.pick()     -> the wrapper's own overload (own methods win, no peel)
//   b.*.pick()   -> the inner type's overload (explicit deref, then UFCS)
//   pick(&b.*)   -> the inner type's &T overload (explicit deref, borrowed)
//   byval(b.*)   -> the inner type's by-value overload (explicit deref value)
//   b.inner()    -> the inner type's overload (implicit peel: Box has none)
// `b.*` is a Point VALUE, so a free call needs `&b.*` for a `&Point`
// parameter - the same rule as any other argument, nothing deref-specific.

type Box = struct(T) { __value: T }

fn op_deref(self: &Box($T)) &T {
    return &self.__value
}

type Point = struct { x: i32, y: i32 }

fn pick(self: &Box(Point)) i32 { return 1 }
fn pick(self: &Point) i32 { return 7 }
fn byval(b: Box(Point)) i32 { return 1 }
fn byval(p: Point) i32 { return 7 }
fn inner(self: &Point) i32 { return 7 }

pub fn main() i32 {
    let b = Box(Point) { __value = Point { x = 1, y = 2 } }
    let own = b.pick()
    let explicit_ufcs = b.*.pick()
    let explicit_ref_arg = pick(&b.*)
    let explicit_val_arg = byval(b.*)
    let implicit = b.inner()
    return own + explicit_ufcs + explicit_ref_arg + explicit_val_arg + implicit
}
