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

    return c match {
        '+' => { self.pos = self.pos + 1; Token.Plus }
        '-' => { self.pos = self.pos + 1; Token.Minus }
        '*' => { self.pos = self.pos + 1; Token.Star }
        '/' => { self.pos = self.pos + 1; Token.Slash }
        '%' => { self.pos = self.pos + 1; Token.Percent }
        '(' => { self.pos = self.pos + 1; Token.LParen }
        ')' => { self.pos = self.pos + 1; Token.RParen }

        // Number (integer or decimal): digit or leading `.`
        '0'..='9' | '.' => {
            const remaining = self.input[self.pos..self.input.len]
            parse_f64(remaining) match {
                Ok((value, consumed)) => {
                    self.pos = self.pos + consumed
                    Token.Number(value)
                }
                Err(_) => {
                    self.pos = self.pos + 1
                    Token.Error
                }
            }
        }

        _ => { self.pos = self.pos + 1; Token.Error }
    }
}
