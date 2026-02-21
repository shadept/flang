//! TEST: define_interpolation
//! EXIT: 42

// Test string concat in interpolation and multiple #() expansions.

#define(make_getter, T: Type, FieldName: Ident) {
    fn get_#(FieldName)(self: &#(T.name)) i32 {
        return self.#(FieldName)
    }
}

type Point = struct {
    x: i32
    y: i32
}

#make_getter(Point, x)
#make_getter(Point, y)

pub fn main() i32 {
    let p = Point { x = 10, y = 32 }
    return p.get_x() + p.get_y()
}
