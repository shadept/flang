pub type Token = enum {
    Number(f64)
    Plus
    Minus
    Star
    Slash
    Percent
    LParen
    RParen
    End
    Error
}

pub type Expr = enum {
    Num(f64)
    Neg(&Expr)
    Add(&Expr, &Expr)
    Sub(&Expr, &Expr)
    Mul(&Expr, &Expr)
    Div(&Expr, &Expr)
    Mod(&Expr, &Expr)
}
