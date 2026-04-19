import calc.ast
import std.char
import std.conv

pub type Lexer = struct {
    input: String
    pos: usize
}

pub fn lexer(input: String) Lexer {
    return .{ input = input, pos = 0 }
}

pub fn next_token(self: &Lexer) Token {
    // Skip whitespace
    while self.pos < self.input.len and is_whitespace(self.input[self.pos]) {
        self.pos = self.pos + 1
    }
    if self.pos >= self.input.len { return Token.End }

    const c = self.input[self.pos]

    // Single-character tokens
    if c == '+' { self.pos = self.pos + 1; return Token.Plus }
    if c == '-' { self.pos = self.pos + 1; return Token.Minus }
    if c == '*' { self.pos = self.pos + 1; return Token.Star }
    if c == '/' { self.pos = self.pos + 1; return Token.Slash }
    if c == '%' { self.pos = self.pos + 1; return Token.Percent }
    if c == '(' { self.pos = self.pos + 1; return Token.LParen }
    if c == ')' { self.pos = self.pos + 1; return Token.RParen }

    // Number (integer or decimal)
    if is_digit(c) or c == '.' {
        const remaining = self.input[self.pos..self.input.len]
        const result = parse_f64(remaining)
        if result.is_ok() {
            const pair = result.unwrap()
            self.pos = self.pos + pair.1
            return Token.Number(pair.0)
        }
        self.pos = self.pos + 1
        return Token.Error
    }

    self.pos = self.pos + 1
    return Token.Error
}
