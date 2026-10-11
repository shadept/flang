// The operator functions of the primitive types (spec 5.2): `a + b` on `i32` is `op_add(a, b)`, so
// a primitive is called, passed and bound by contract exactly as a user type with the same
// functions is. Each body is the built-in operation it names; `#inline` folds the call back into
// it.

// What every primitive orders and compares with: `bool` and `char` stop here.
#define(cmp_ops, T: Ident) {
    #inline
    pub fn op_eq(a: #(T), b: #(T)) bool {
        return a == b
    }

    #inline
    pub fn op_ne(a: #(T), b: #(T)) bool {
        return a != b
    }

    #inline
    pub fn op_lt(a: #(T), b: #(T)) bool {
        return a < b
    }

    #inline
    pub fn op_gt(a: #(T), b: #(T)) bool {
        return a > b
    }

    #inline
    pub fn op_le(a: #(T), b: #(T)) bool {
        return a <= b
    }

    #inline
    pub fn op_ge(a: #(T), b: #(T)) bool {
        return a >= b
    }
}

// What every number adds.
#define(num_ops, T: Ident) {
    #inline
    pub fn op_add(a: #(T), b: #(T)) #(T) {
        return a + b
    }

    #inline
    pub fn op_sub(a: #(T), b: #(T)) #(T) {
        return a - b
    }

    #inline
    pub fn op_mul(a: #(T), b: #(T)) #(T) {
        return a * b
    }

    #inline
    pub fn op_div(a: #(T), b: #(T)) #(T) {
        return a / b
    }

    #inline
    pub fn op_mod(a: #(T), b: #(T)) #(T) {
        return a % b
    }
}

// Negation, for the signed numbers.
#define(neg_ops, T: Ident) {
    #inline
    pub fn op_neg(a: #(T)) #(T) {
        return -a
    }
}

// What every integer adds on top: the bitwise and shift operators.
#define(int_ops, T: Ident) {
    #inline
    pub fn op_band(a: #(T), b: #(T)) #(T) {
        return a & b
    }

    #inline
    pub fn op_bor(a: #(T), b: #(T)) #(T) {
        return a | b
    }

    #inline
    pub fn op_bxor(a: #(T), b: #(T)) #(T) {
        return a ^ b
    }

    #inline
    pub fn op_shl(a: #(T), b: #(T)) #(T) {
        return a << b
    }

    #inline
    pub fn op_shr(a: #(T), b: #(T)) #(T) {
        return a >> b
    }

    #inline
    pub fn op_ushr(a: #(T), b: #(T)) #(T) {
        return a >>> b
    }

    #inline
    pub fn op_bnot(a: #(T)) #(T) {
        return ~a
    }
}

// `bool`'s logical operators: `&`, `|`, `^` without short-circuit, and `!`.
#define(bool_ops, T: Ident) {
    #inline
    pub fn op_band(a: #(T), b: #(T)) #(T) {
        return a & b
    }

    #inline
    pub fn op_bor(a: #(T), b: #(T)) #(T) {
        return a | b
    }

    #inline
    pub fn op_bxor(a: #(T), b: #(T)) #(T) {
        return a ^ b
    }

    #inline
    pub fn op_not(a: #(T)) #(T) {
        return !a
    }
}

#cmp_ops(i8)
#cmp_ops(i16)
#cmp_ops(i32)
#cmp_ops(i64)
#cmp_ops(isize)
#cmp_ops(u8)
#cmp_ops(u16)
#cmp_ops(u32)
#cmp_ops(u64)
#cmp_ops(usize)
#cmp_ops(f32)
#cmp_ops(f64)
#cmp_ops(bool)
#cmp_ops(char)

#num_ops(i8)
#num_ops(i16)
#num_ops(i32)
#num_ops(i64)
#num_ops(isize)
#num_ops(f32)
#num_ops(f64)
#num_ops(u8)
#num_ops(u16)
#num_ops(u32)
#num_ops(u64)
#num_ops(usize)

#neg_ops(i8)
#neg_ops(i16)
#neg_ops(i32)
#neg_ops(i64)
#neg_ops(isize)
#neg_ops(f32)
#neg_ops(f64)

#int_ops(i8)
#int_ops(i16)
#int_ops(i32)
#int_ops(i64)
#int_ops(isize)
#int_ops(u8)
#int_ops(u16)
#int_ops(u32)
#int_ops(u64)
#int_ops(usize)

#bool_ops(bool)
