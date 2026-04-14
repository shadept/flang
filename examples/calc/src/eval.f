import calc.ast

pub fn eval(expr: &Expr) f64 {
    return expr.* match {
        Num(n) => n,
        Neg(inner) => 0.0 - eval(inner),
        Add(l, r) => eval(l) + eval(r),
        Sub(l, r) => eval(l) - eval(r),
        Mul(l, r) => eval(l) * eval(r),
        Div(l, r) => {
            const rhs = eval(r)
            if rhs == 0.0 { panic("division by zero") }
            eval(l) / rhs
        },
        Mod(l, r) => {
            const rhs = eval(r)
            if rhs == 0.0 { panic("modulo by zero") }
            eval(l) % rhs
        }
    }
}
