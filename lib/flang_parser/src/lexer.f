// Lexer — turns a source buffer into a stream of Tokens with trivia.
//
// Trivia attachment policy:
//   - Leading trivia: every whitespace and line-comment chunk between the
//     previous token's trailing trivia and the current token's first byte.
//   - Trailing trivia: at most one run of horizontal whitespace, at most one
//     line comment, and at most one newline immediately after the token's
//     text. Everything past that newline belongs to the next token's
//     leading trivia.
//
// Invariant: concatenating `leading + text + trailing` across every token
// in order reproduces the source file byte-for-byte.

import std.char
import std.list
import std.option
import std.string
import flang_parser.token
import flang_parser.trivia

pub fn parser_version() String {
    return project_info().version
}

pub type Lexer = struct {
    source: String
    position: usize
}

pub fn lexer(source: String) Lexer {
    return .{ source = source, position = 0 }
}

pub fn tokenize(self: &Lexer) List(Token) {
    let tokens: List(Token) = list(64)
    loop {
        const tok = self.next_token()
        const is_eof = tok.kind == TokenKind.Eof
        tokens.push(tok)
        if is_eof { break }
    }
    return tokens
}

pub fn next_token(self: &Lexer) Token {
    const leading = lex_leading_trivia(self)
    const token_start = self.position
    let kind = TokenKind.Eof
    if self.position < self.source.len {
        kind = lex_token_text(self)
    }
    const text = self.source[token_start..self.position]
    const trailing = lex_trailing_trivia(self)
    return Token {
        kind = kind,
        text = text,
        offset = token_start,
        leading = leading,
        trailing = trailing,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Trivia
// ─────────────────────────────────────────────────────────────────────────

fn lex_leading_trivia(self: &Lexer) List(Trivia) {
    let trivia: List(Trivia) = list(0)
    const text = self.source
    loop {
        if self.position >= text.len { break }
        const ch = text[self.position]
        if is_whitespace_byte(ch) {
            const start = self.position
            while self.position < text.len and is_whitespace_byte(text[self.position]) {
                self.position = self.position + 1
            }
            trivia.push(Trivia {
                kind = TriviaKind.Whitespace,
                text = text[start..self.position],
            })
            continue
        }
        if ch == '/' and self.position + 1 < text.len and text[self.position + 1] == '/' {
            const start = self.position
            self.position = self.position + 2
            while self.position < text.len and text[self.position] != '\n' {
                self.position = self.position + 1
            }
            trivia.push(Trivia {
                kind = TriviaKind.LineComment,
                text = text[start..self.position],
            })
            continue
        }
        break
    }
    return trivia
}

fn lex_trailing_trivia(self: &Lexer) List(Trivia) {
    let trivia: List(Trivia) = list(0)
    const text = self.source

    const hws_start = self.position
    while self.position < text.len and is_horizontal_whitespace(text[self.position]) {
        self.position = self.position + 1
    }
    if self.position > hws_start {
        trivia.push(Trivia {
            kind = TriviaKind.Whitespace,
            text = text[hws_start..self.position],
        })
    }

    if self.position + 1 < text.len and text[self.position] == '/' and text[self.position + 1] == '/' {
        const cstart = self.position
        self.position = self.position + 2
        while self.position < text.len and text[self.position] != '\n' {
            self.position = self.position + 1
        }
        trivia.push(Trivia {
            kind = TriviaKind.LineComment,
            text = text[cstart..self.position],
        })
    }

    if self.position < text.len and text[self.position] == '\n' {
        const nstart = self.position
        self.position = self.position + 1
        trivia.push(Trivia {
            kind = TriviaKind.Whitespace,
            text = text[nstart..self.position],
        })
    }

    return trivia
}

fn is_horizontal_whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r'
}

fn is_whitespace_byte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n'
}

// ─────────────────────────────────────────────────────────────────────────
// Token text
// ─────────────────────────────────────────────────────────────────────────

// On entry self.position points at a non-trivia byte; on return it is the
// first byte past the consumed token's text.
fn lex_token_text(self: &Lexer) TokenKind {
    const text = self.source
    const start = self.position
    const ch = text[start]

    if is_digit(ch) {
        return lex_number(self)
    }
    if ch == '"' {
        return lex_string(self)
    }
    if ch == '\'' {
        return lex_char_literal(self, TokenKind.CharLiteral)
    }
    if is_alpha(ch) or ch == '_' {
        if ch == 'b' and start + 1 < text.len and text[start + 1] == '\'' {
            self.position = start + 1
            return lex_char_literal(self, TokenKind.ByteLiteral)
        }
        return lex_identifier_or_keyword(self)
    }

    // RFC-006 #18: `//` is the only comment form.
    if ch == '/' and start + 1 < text.len and text[start + 1] == '*' {
        self.position = start + 2
        return TokenKind.BadToken
    }

    if start + 2 < text.len {
        const c1 = text[start + 1]
        const c2 = text[start + 2]
        if ch == '>' and c1 == '>' and c2 == '>' {
            self.position = start + 3
            return TokenKind.UnsignedShiftRight
        }
        if ch == '.' and c1 == '.' and c2 == '=' {
            self.position = start + 3
            return TokenKind.DotDotEquals
        }
    }

    if start + 1 < text.len {
        const two = match_two_char(ch, text[start + 1])
        if two.is_some() {
            self.position = start + 2
            return two.unwrap()
        }
    }

    self.position = start + 1
    return single_char_kind(ch)
}

fn match_two_char(a: u8, b: u8) TokenKind? {
    if a == '.' and b == '.' { return TokenKind.DotDot }
    if a == '=' and b == '=' { return TokenKind.EqualsEquals }
    if a == '=' and b == '>' { return TokenKind.FatArrow }
    if a == '!' and b == '=' { return TokenKind.NotEquals }
    if a == '<' and b == '<' { return TokenKind.ShiftLeft }
    if a == '<' and b == '=' { return TokenKind.LessThanOrEqual }
    if a == '>' and b == '>' { return TokenKind.ShiftRight }
    if a == '>' and b == '=' { return TokenKind.GreaterThanOrEqual }
    if a == '?' and b == '?' { return TokenKind.QuestionQuestion }
    if a == '?' and b == '.' { return TokenKind.QuestionDot }
    return null
}

fn single_char_kind(ch: u8) TokenKind {
    return ch match {
        '(' => TokenKind.OpenParenthesis,
        ')' => TokenKind.CloseParenthesis,
        '{' => TokenKind.OpenBrace,
        '}' => TokenKind.CloseBrace,
        '[' => TokenKind.OpenBracket,
        ']' => TokenKind.CloseBracket,
        ':' => TokenKind.Colon,
        '=' => TokenKind.Equals,
        ';' => TokenKind.Semicolon,
        ',' => TokenKind.Comma,
        '&' => TokenKind.Ampersand,
        '|' => TokenKind.Pipe,
        '^' => TokenKind.Caret,
        '?' => TokenKind.Question,
        '+' => TokenKind.Plus,
        '-' => TokenKind.Minus,
        '*' => TokenKind.Star,
        '/' => TokenKind.Slash,
        '%' => TokenKind.Percent,
        '<' => TokenKind.LessThan,
        '>' => TokenKind.GreaterThan,
        '.' => TokenKind.Dot,
        '#' => TokenKind.Hash,
        '$' => TokenKind.Dollar,
        '!' => TokenKind.Bang,
        '~' => TokenKind.Tilde,
        else => TokenKind.BadToken,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Numbers
// ─────────────────────────────────────────────────────────────────────────

fn lex_number(self: &Lexer) TokenKind {
    const text = self.source
    const start = self.position
    let is_float = false

    if text[start] == '0' and start + 1 < text.len
        and (text[start + 1] == 'x' or text[start + 1] == 'X') {
        self.position = start + 2
        while self.position < text.len
            and (is_hex_digit(text[self.position]) or text[self.position] == '_') {
            self.position = self.position + 1
        }
        return TokenKind.Integer
    }

    while self.position < text.len
        and (is_digit(text[self.position]) or text[self.position] == '_') {
        self.position = self.position + 1
    }

    if self.position < text.len and text[self.position] == '.'
        and self.position + 1 < text.len and is_digit(text[self.position + 1]) {
        is_float = true
        self.position = self.position + 1
        while self.position < text.len
            and (is_digit(text[self.position]) or text[self.position] == '_') {
            self.position = self.position + 1
        }
    }

    if self.position < text.len and (text[self.position] == 'e' or text[self.position] == 'E') {
        is_float = true
        self.position = self.position + 1
        if self.position < text.len
            and (text[self.position] == '+' or text[self.position] == '-') {
            self.position = self.position + 1
        }
        while self.position < text.len
            and (is_digit(text[self.position]) or text[self.position] == '_') {
            self.position = self.position + 1
        }
    }

    if self.position < text.len and text[self.position] == 'f'
        and self.position + 1 < text.len
        and (text[self.position + 1] == '3' or text[self.position + 1] == '6') {
        const suffix_start = self.position
        self.position = self.position + 2
        if self.position < text.len and is_digit(text[self.position]) {
            self.position = self.position + 1
        }
        const sfx = text[suffix_start..self.position]
        if sfx == "f32" or sfx == "f64" {
            is_float = true
        } else {
            self.position = suffix_start
        }
    }

    if is_float { return TokenKind.Float }

    if self.position < text.len
        and (text[self.position] == 'i' or text[self.position] == 'u') {
        const suffix_start = self.position
        while self.position < text.len and is_ident_continuation(text[self.position]) {
            self.position = self.position + 1
        }
        const sfx = text[suffix_start..self.position]
        if !is_valid_int_suffix(sfx) {
            self.position = suffix_start
        }
    }
    return TokenKind.Integer
}

fn is_valid_int_suffix(s: String) bool {
    if s == "i8" { return true }
    if s == "i16" { return true }
    if s == "i32" { return true }
    if s == "i64" { return true }
    if s == "isize" { return true }
    if s == "u8" { return true }
    if s == "u16" { return true }
    if s == "u32" { return true }
    if s == "u64" { return true }
    if s == "usize" { return true }
    return false
}

fn is_hex_digit(c: u8) bool {
    if is_digit(c) { return true }
    if c >= 'a' and c <= 'f' { return true }
    if c >= 'A' and c <= 'F' { return true }
    return false
}

fn is_ident_continuation(c: u8) bool {
    return is_alnum(c) or c == '_'
}

// ─────────────────────────────────────────────────────────────────────────
// String / char literals
// ─────────────────────────────────────────────────────────────────────────

fn lex_string(self: &Lexer) TokenKind {
    const text = self.source
    self.position = self.position + 1
    while self.position < text.len and text[self.position] != '"' {
        if text[self.position] == '\\' and self.position + 1 < text.len {
            self.position = self.position + 2
        } else {
            self.position = self.position + 1
        }
    }
    if self.position >= text.len { return TokenKind.BadToken }
    self.position = self.position + 1
    return TokenKind.StringLiteral
}

fn lex_char_literal(self: &Lexer, kind: TokenKind) TokenKind {
    const text = self.source
    self.position = self.position + 1
    if self.position >= text.len { return TokenKind.BadToken }

    if text[self.position] == '\\' and self.position + 1 < text.len {
        self.position = self.position + 2
        if self.position - 1 < text.len and text[self.position - 1] == 'u' {
            let count = 0usize
            while self.position < text.len
                and is_hex_digit(text[self.position])
                and count < 6 {
                self.position = self.position + 1
                count = count + 1
            }
        }
    } else {
        self.position = self.position + 1
    }

    if self.position >= text.len { return TokenKind.BadToken }
    if text[self.position] != '\'' {
        while self.position < text.len and text[self.position] != '\'' and text[self.position] != '\n' {
            self.position = self.position + 1
        }
        if self.position < text.len and text[self.position] == '\'' {
            self.position = self.position + 1
        }
        return TokenKind.BadToken
    }
    self.position = self.position + 1
    return kind
}

// ─────────────────────────────────────────────────────────────────────────
// Identifiers and keywords
// ─────────────────────────────────────────────────────────────────────────

fn lex_identifier_or_keyword(self: &Lexer) TokenKind {
    const text = self.source
    const start = self.position
    while self.position < text.len and is_ident_continuation(text[self.position]) {
        self.position = self.position + 1
    }
    return keyword_or_identifier(text[start..self.position])
}

fn keyword_or_identifier(word: String) TokenKind {
    if word == "pub" { return TokenKind.Pub }
    if word == "fn" { return TokenKind.Fn }
    if word == "return" { return TokenKind.Return }
    if word == "let" { return TokenKind.Let }
    if word == "const" { return TokenKind.Const }
    if word == "if" { return TokenKind.If }
    if word == "else" { return TokenKind.Else }
    if word == "for" { return TokenKind.For }
    if word == "loop" { return TokenKind.Loop }
    if word == "while" { return TokenKind.While }
    if word == "in" { return TokenKind.In }
    if word == "break" { return TokenKind.Break }
    if word == "continue" { return TokenKind.Continue }
    if word == "defer" { return TokenKind.Defer }
    if word == "import" { return TokenKind.Import }
    if word == "struct" { return TokenKind.Struct }
    if word == "enum" { return TokenKind.Enum }
    if word == "match" { return TokenKind.Match }
    if word == "as" { return TokenKind.As }
    if word == "test" { return TokenKind.Test }
    if word == "type" { return TokenKind.Type }
    if word == "and" { return TokenKind.And }
    if word == "or" { return TokenKind.Or }
    if word == "true" { return TokenKind.True }
    if word == "false" { return TokenKind.False }
    if word == "null" { return TokenKind.Null }
    if word == "_" { return TokenKind.Underscore }
    return TokenKind.Identifier
}
