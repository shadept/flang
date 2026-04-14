import calc.ast
import calc.lexer
import std.allocator

pub type Parser = struct {
    lex: Lexer
    current: Token
    arena: &Allocator
}

pub fn parser(input: String, arena: &Allocator) Parser {
    let lex = lexer(input)
    const first = lex.next_token()
    return .{ lex = lex, current = first, arena = arena }
}

fn advance(self: &Parser) {
    self.current = self.lex.next_token()
}

fn alloc_expr(self: &Parser, expr: Expr) &Expr {
    const ptr = self.arena.new(Expr)
    ptr.* = expr
    return ptr
}

// parse: entry point — parses a full expression, expects End token after
pub fn parse(self: &Parser) &Expr {
    const expr = parse_additive(self)

    self.current match {
        End => {},
        else => panic("unexpected token after expression")
    }

    return expr
}

// additive: handles + and -
fn parse_additive(self: &Parser) &Expr {
    let left = parse_multiplicative(self)

    loop {
        self.current match {
            Plus => {
                advance(self)
                const right = parse_multiplicative(self)
                left = alloc_expr(self, Expr.Add(left, right))
            },
            Minus => {
                advance(self)
                const right = parse_multiplicative(self)
                left = alloc_expr(self, Expr.Sub(left, right))
            },
            else => { return left }
        }
    }

    return left
}

// multiplicative: handles *, /, %
fn parse_multiplicative(self: &Parser) &Expr {
    let left = parse_unary(self)

    loop {
        self.current match {
            Star => {
                advance(self)
                const right = parse_unary(self)
                left = alloc_expr(self, Expr.Mul(left, right))
            },
            Slash => {
                advance(self)
                const right = parse_unary(self)
                left = alloc_expr(self, Expr.Div(left, right))
            },
            Percent => {
                advance(self)
                const right = parse_unary(self)
                left = alloc_expr(self, Expr.Mod(left, right))
            },
            else => { return left }
        }
    }

    return left
}

// unary: handles unary -
fn parse_unary(self: &Parser) &Expr {
    let is_neg = false
    self.current match {
        Minus => { is_neg = true },
        else => {}
    }

    if is_neg {
        advance(self)
        const operand = parse_unary(self)
        return alloc_expr(self, Expr.Neg(operand))
    }

    return parse_primary(self)
}

// primary: numbers and parenthesized expressions
fn parse_primary(self: &Parser) &Expr {
    let is_num = false
    let num_val: f64 = 0.0
    let is_paren = false

    self.current match {
        Number(n) => { is_num = true; num_val = n },
        LParen => { is_paren = true },
        else => panic("unexpected token in expression")
    }

    if is_num {
        advance(self)
        return alloc_expr(self, Expr.Num(num_val))
    }

    // Must be LParen
    advance(self)
    const expr = parse_additive(self)
    self.current match {
        RParen => { advance(self) },
        else => panic("expected closing parenthesis")
    }
    return expr
}
