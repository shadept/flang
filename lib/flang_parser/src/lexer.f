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

import std.allocator
import std.char
import std.encoding.utf8
import std.list
import std.option
import std.string
import std.string_builder
import flang_parser.token
import flang_parser.trivia

// Version string of the flang_parser library, sourced from its
// flang.toml. Useful for tools (LSP, dump_tokens, formatter) that
// surface "compiled against parser X" diagnostics.
pub fn parser_version() String {
    return project_info().version
}

// One level of an active `$"..."`. Nested interp pushes another frame.
// Exactly one of in_segment / in_format_spec is true, or both are false
// (hole mode — the lexer runs as a normal token scanner with the bracket
// counters tracking which `}` closes the hole).
type InterpFrame = struct {
    in_segment: bool
    in_format_spec: bool
    // Bracket depths *inside* the current hole. The hole-closing `}` is
    // the first un-matched `}`; matched `}` (paired with a `{` inside
    // the hole) decrements the depth and stays inside the hole.
    brace_depth: usize
    paren_depth: usize
    bracket_depth: usize
}

pub type Lexer = struct {
    source: String
    position: usize
    line: usize
    // Backs every list the lexer allocates — interp_stack, per-token
    // trivia lists, and the result of `tokenize()`. Resolved at
    // construction (the optional `allocator` argument to `lexer()` is
    // run through `or_global()` once), so internal call sites just
    // forward `self.allocator` without re-resolving.
    allocator: &Allocator
    interp_stack: List(InterpFrame)
    // Set inline on `$"` (Dollar adjacent to quote) and by the parser
    // before eating the prefix for the `$(args)"..."` / `$ident"..."`
    // forms; consumed by next_token() to decide whether the next `"`
    // opens an interp string or a plain string literal.
    mark_next_string_interp: bool
    // Single-slot queue so a segment-boundary or format-spec terminator
    // can fan out into two tokens (e.g. InterpSegment + InterpHoleStart).
    has_pending: bool
    pending_token: Token
}

// Construct a Lexer over `source`. The source is borrowed: every
// Token's `text`, `leading`, and `trailing` will point into it, so
// `source` must outlive the produced tokens.
//
// `allocator` backs every list the lexer (and the tokens it produces)
// allocates. Pass `null` to default to the global allocator; pass an
// arena / fixed-buffer allocator when you want all lex output to share
// a single lifetime that can be dropped in one shot. Resolved once
// here so the rest of the lexer can use `self.allocator` directly.
pub fn lexer(source: String, allocator: &Allocator? = null) Lexer {
    const resolved = allocator.or_global()
    return .{
        source = source,
        position = 0,
        line = 0,
        allocator = resolved,
        interp_stack = list(0, resolved),
        mark_next_string_interp = false,
        has_pending = false,
        pending_token = empty_token(resolved),
    }
}

// Release the lexer's own bookkeeping: the interp frame stack and any
// token queued ahead (only relevant if the caller abandons the lexer
// between `next_token()` calls — `tokenize()` always drains the queue
// before returning). Tokens already handed to the caller are
// independent; deinit the returned `List(Token)` to free them.
pub fn deinit(self: &Lexer) {
    self.interp_stack.deinit()
    if self.has_pending {
        self.pending_token.deinit()
        self.has_pending = false
    }
}

// Mark the next `"` as the opener of an interpolated string. The flag
// is consumed by the next `next_token()` call: if the lexer's cursor
// sits on `"` (no intervening trivia), it enters interp mode and emits
// `InterpStringStart`; otherwise the flag is silently dropped and a
// normal token is produced.
//
// Drives the `$(args)"..."` and `$ident"..."` interp forms — the
// parser calls this immediately before eating the closing `)` or the
// prefix identifier. The `$"..."` form is recognised inline by the
// lexer (Dollar adjacent to `"`) and does not need this hook.
pub fn mark_next_string_interp(self: &Lexer) {
    self.mark_next_string_interp = true
}

// Drive `next_token()` to completion and collect every token —
// including the terminating `Eof` — into a list. The returned list
// owns its storage; callers must `deinit()` it. The lexer's position
// is at end-of-source on return.
//
// `mark_next_string_interp()` cannot be called between tokens when
// using this entry point, so the `$(args)"..."` and `$ident"..."`
// interp forms degrade to `Dollar + … + StringLiteral`. Use
// `next_token()` directly when you need full RFC-004 coverage.
pub fn tokenize(self: &Lexer) List(Token) {
    let tokens: List(Token) = list(64, self.allocator)
    loop {
        const tok = self.next_token()
        const is_eof = tok.kind == TokenKind.Eof
        tokens.push(tok)
        if is_eof { break }
    }
    return tokens
}

// Produce the next token from the source, advancing the lexer's
// position. Always returns a token — once the source is exhausted,
// every call returns `Eof` (the formatter / parser are expected to
// stop at the first `Eof`).
//
// Dispatch order:
//   1. Drain a queued token (segment boundaries fan out into two).
//   2. Inside an interp segment / format-spec, scan raw characters —
//      these modes do not eat trivia.
//   3. If a `"` was marked as the next interp opener, consume it.
//   4. Otherwise: leading trivia → token text → (hole-mode intercept)
//      → trailing trivia.
pub fn next_token(self: &Lexer) Token {
    if self.has_pending {
        const queued = self.pending_token
        self.has_pending = false
        self.pending_token = empty_token(self.allocator)
        return queued
    }

    if self.interp_stack.len > 0 {
        const top_idx = self.interp_stack.len - 1
        if self.interp_stack[top_idx].in_segment {
            return lex_segment(self)
        }
        if self.interp_stack[top_idx].in_format_spec {
            return lex_format_spec(self)
        }
    }

    if self.mark_next_string_interp {
        self.mark_next_string_interp = false
        if self.position < self.source.len and self.source[self.position] == '"' {
            return begin_interp_string(self)
        }
    }

    const leading = lex_leading_trivia(self)
    const token_start = self.position
    const token_line = self.line
    let kind = TokenKind.Eof
    if self.position < self.source.len {
        kind = lex_token_text(self)
    }
    const text = self.source[token_start..self.position]

    // Hole-mode intercept: a `}` that doesn't match anything inside the
    // hole becomes InterpHoleEnd; an unbracketed `:` becomes
    // InterpFormatSep. These intercepted tokens border raw segment / spec
    // bytes, so they get no trailing trivia.
    if self.interp_stack.len > 0 {
        const top_idx = self.interp_stack.len - 1
        const frame = self.interp_stack[top_idx]
        if !frame.in_segment and !frame.in_format_spec {
            const adjusted = adjust_for_hole_mode(self, kind, top_idx)
            if adjusted.is_some() {
                const new_kind = adjusted.unwrap()
                return Token {
                    kind = new_kind,
                    text = text,
                    offset = token_start,
                    line = token_line,
                    leading = leading,
                    trailing = empty_trivia(),
                    allocator = self.allocator,
                }
            }
        }
    }

    const trailing = lex_trailing_trivia(self)
    return Token {
        kind = kind,
        text = text,
        offset = token_start,
        line = token_line,
        leading = leading,
        trailing = trailing,
        allocator = self.allocator,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Trivia
// ─────────────────────────────────────────────────────────────────────────

// Empty `Trivia[]` — no allocation, ptr=null, len=0. Used everywhere a
// token is known to have no leading or trailing trivia (interp
// boundaries, BadToken recovery exits, the EOF placeholder).
fn empty_trivia() Trivia[] {
    let zero: usize = 0
    return slice_from_raw_parts(zero as &Trivia, 0)
}

fn lex_leading_trivia(self: &Lexer) Trivia[] {
    let trivia: List(Trivia) = list(0, self.allocator)
    const text = self.source
    loop {
        if self.position >= text.len { break }
        const ch = text[self.position]
        if is_whitespace_byte(ch) {
            const start = self.position
            while self.position < text.len and is_whitespace_byte(text[self.position]) {
                if text[self.position] == '\n' { self.line = self.line + 1 }
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
    return trivia.to_owned_slice().0
}

fn lex_trailing_trivia(self: &Lexer) Trivia[] {
    let trivia: List(Trivia) = list(0, self.allocator)
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
        self.line = self.line + 1
        trivia.push(Trivia {
            kind = TriviaKind.Whitespace,
            text = text[nstart..self.position],
        })
    }

    return trivia.to_owned_slice().0
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
    if ch == '$' {
        // Strict adjacency only — a stray `$` next to whitespace must not
        // arm the interp scanner.
        if self.position < text.len and text[self.position] == '"' {
            self.mark_next_string_interp = true
        }
        return TokenKind.Dollar
    }
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
    let bad = false
    while self.position < text.len and text[self.position] != '"' {
        if text[self.position] == '\\' and self.position + 1 < text.len {
            self.position = self.position + 1
            const esc = text[self.position]
            if esc == 'u' {
                self.position = self.position + 1
                if !consume_unicode_escape(self) {
                    bad = true
                }
            } else {
                self.position = self.position + 1
            }
        } else {
            if text[self.position] == '\n' { self.line = self.line + 1 }
            self.position = self.position + 1
        }
    }
    if self.position >= text.len { return TokenKind.BadToken }
    self.position = self.position + 1
    if bad { return TokenKind.BadToken }
    return TokenKind.StringLiteral
}

fn lex_char_literal(self: &Lexer, kind: TokenKind) TokenKind {
    const text = self.source
    self.position = self.position + 1
    if self.position >= text.len { return TokenKind.BadToken }
    if text[self.position] == '\'' {
        // Empty literal — eat the closing quote so recovery doesn't loop.
        self.position = self.position + 1
        return TokenKind.BadToken
    }

    let codepoint: u32 = 0
    let bad = false
    if text[self.position] == '\\' and self.position + 1 < text.len {
        self.position = self.position + 1
        const esc = text[self.position]
        if esc == 'u' {
            self.position = self.position + 1
            const cp_opt = consume_unicode_escape_value(self)
            if cp_opt.is_none() {
                bad = true
            } else if kind == TokenKind.ByteLiteral {
                bad = true
            } else {
                codepoint = cp_opt.unwrap()
            }
        } else {
            codepoint = decode_simple_escape(esc) as u32
            self.position = self.position + 1
        }
    } else {
        const first = text[self.position]
        codepoint = first as u32
        self.position = self.position + 1
        let extra = 0usize
        if first >= 0xF0 {
            extra = 3
        } else if first >= 0xE0 {
            extra = 2
        } else if first >= 0xC0 {
            extra = 1
        }
        let i = 0usize
        loop {
            if i >= extra { break }
            if self.position >= text.len { break }
            const cont = text[self.position]
            const masked = cont & 0xC0
            if masked != 0x80 { break }
            self.position = self.position + 1
            i = i + 1
        }
    }

    if self.position < text.len and text[self.position] != '\'' {
        bad = true
        // Stop at newline — single-quoted literals never span lines.
        while self.position < text.len and text[self.position] != '\'' and text[self.position] != '\n' {
            self.position = self.position + 1
        }
    }
    if self.position >= text.len { return TokenKind.BadToken }
    if text[self.position] != '\'' { return TokenKind.BadToken }
    self.position = self.position + 1

    if bad { return TokenKind.BadToken }
    if kind == TokenKind.ByteLiteral and codepoint > 255 {
        return TokenKind.BadToken
    }
    return kind
}

fn consume_unicode_escape(self: &Lexer) bool {
    return consume_unicode_escape_value(self).is_some()
}

fn consume_unicode_escape_value(self: &Lexer) u32? {
    const text = self.source
    let value: u32 = 0
    let count = 0usize
    while self.position < text.len and is_hex_digit(text[self.position]) and count < 6 {
        value = value * 16 + (hex_digit_value(text[self.position]) as u32)
        self.position = self.position + 1
        count = count + 1
    }
    if count == 0 { return null }
    if value > 0x10FFFF { return null }
    return value
}

fn hex_digit_value(c: u8) u8 {
    if c >= '0' and c <= '9' { return c - '0' }
    if c >= 'a' and c <= 'f' { return c - 'a' + 10 }
    if c >= 'A' and c <= 'F' { return c - 'A' + 10 }
    return 0
}

fn decode_simple_escape(c: u8) u8 {
    return c match {
        'n' => '\n' as u8,
        't' => '\t' as u8,
        'r' => '\r' as u8,
        '\\' => '\\' as u8,
        '"' => '"' as u8,
        '\'' => '\'' as u8,
        '0' => 0u8,
        else => c,
    }
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

// ─────────────────────────────────────────────────────────────────────────
// Interpolated strings (RFC-004)
//
// State machine over a stack of InterpFrames. The lexer alternates between
// three modes per active interp:
//   - segment    : raw bytes between `"` / `}` and the next `{` / `"`
//   - hole       : normal token scanning; bracket counters track which `}`
//                  closes the hole
//   - format spec: raw bytes between `:` and `}` of the current hole
// Transitions:
//   begin_interp_string                → push frame, segment mode
//   lex_segment hits `{`               → hole mode
//   lex_segment hits `"`               → pop frame
//   adjust_for_hole_mode unmatched `}` → segment mode (queues HoleEnd)
//   adjust_for_hole_mode unbracketed `:` → format-spec mode
//   lex_format_spec hits `}`           → segment mode (queues HoleEnd)
// ─────────────────────────────────────────────────────────────────────────

fn begin_interp_string(self: &Lexer) Token {
    const token_start = self.position
    const token_line = self.line
    self.position = self.position + 1
    self.interp_stack.push(InterpFrame {
        in_segment = true,
        in_format_spec = false,
        brace_depth = 0,
        paren_depth = 0,
        bracket_depth = 0,
    })
    return Token {
        kind = TokenKind.InterpStringStart,
        text = self.source[token_start..self.position],
        offset = token_start,
        line = token_line,
        leading = empty_trivia(),
        trailing = empty_trivia(),
        allocator = self.allocator,
    }
}

// Scan raw segment bytes. `{` queues InterpHoleStart and switches to
// hole mode; `"` queues InterpStringEnd and pops the frame. `{{` / `}}`
// are doubling escapes (consumed here as raw bytes — the segment keeps
// its raw shape; decode_interp_segment expands them).
fn lex_segment(self: &Lexer) Token {
    const text = self.source
    const seg_start = self.position
    const seg_line = self.line
    const frame_idx = self.interp_stack.len - 1

    loop {
        if self.position >= text.len { break }
        const c = text[self.position]

        if c == '"' {
            const seg_text = text[seg_start..self.position]
            const close_start = self.position
            const close_line = self.line
            self.position = self.position + 1
            self.interp_stack.pop()
            const end_tok = Token {
                kind = TokenKind.InterpStringEnd,
                text = text[close_start..self.position],
                offset = close_start,
                line = close_line,
                leading = empty_trivia(),
                trailing = empty_trivia(),
                allocator = self.allocator,
            }
            queue_token(self, end_tok)
            return Token {
                kind = TokenKind.InterpSegment,
                text = seg_text,
                offset = seg_start,
                line = seg_line,
                leading = empty_trivia(),
                trailing = empty_trivia(),
                allocator = self.allocator,
            }
        }

        if c == '{' {
            if self.position + 1 < text.len and text[self.position + 1] == '{' {
                self.position = self.position + 2
                continue
            }
            const seg_text = text[seg_start..self.position]
            const hole_start_pos = self.position
            const hole_line = self.line
            self.position = self.position + 1
            self.interp_stack[frame_idx].in_segment = false
            self.interp_stack[frame_idx].brace_depth = 0
            self.interp_stack[frame_idx].paren_depth = 0
            self.interp_stack[frame_idx].bracket_depth = 0
            const hole_tok = Token {
                kind = TokenKind.InterpHoleStart,
                text = text[hole_start_pos..self.position],
                offset = hole_start_pos,
                line = hole_line,
                leading = empty_trivia(),
                trailing = empty_trivia(),
                allocator = self.allocator,
            }
            queue_token(self, hole_tok)
            return Token {
                kind = TokenKind.InterpSegment,
                text = seg_text,
                offset = seg_start,
                line = seg_line,
                leading = empty_trivia(),
                trailing = empty_trivia(),
                allocator = self.allocator,
            }
        }

        if c == '}' {
            if self.position + 1 < text.len and text[self.position + 1] == '}' {
                self.position = self.position + 2
                continue
            }
            const bad_start = self.position
            const bad_line = self.line
            self.position = self.position + 1
            return Token {
                kind = TokenKind.BadToken,
                text = text[bad_start..self.position],
                offset = bad_start,
                line = bad_line,
                leading = empty_trivia(),
                trailing = empty_trivia(),
                allocator = self.allocator,
            }
        }

        if c == '\\' and self.position + 1 < text.len {
            const esc_start = self.position
            self.position = self.position + 1
            const esc = text[self.position]
            if esc == 'u' {
                self.position = self.position + 1
                if !consume_unicode_escape(self) {
                    self.position = esc_start
                    const bad_line = self.line
                    self.position = self.position + 2
                    return Token {
                        kind = TokenKind.BadToken,
                        text = text[esc_start..self.position],
                        offset = esc_start,
                        line = bad_line,
                        leading = empty_trivia(),
                        trailing = empty_trivia(),
                        allocator = self.allocator,
                    }
                }
                continue
            }
            self.position = self.position + 1
            continue
        }

        if c == '\n' { self.line = self.line + 1 }
        self.position = self.position + 1
    }

    // Unterminated segment — outer interp frames are unrecoverable too.
    while self.interp_stack.len > 0 { self.interp_stack.pop() }
    return Token {
        kind = TokenKind.BadToken,
        text = text[seg_start..self.position],
        offset = seg_start,
        line = seg_line,
        leading = empty_trivia(),
        trailing = empty_trivia(),
        allocator = self.allocator,
    }
}

// Scan raw format-spec bytes between `:` and `}`. No escape handling —
// `{x:.2}` yields spec text `.2`. Closes the hole; queues InterpHoleEnd.
fn lex_format_spec(self: &Lexer) Token {
    const text = self.source
    const spec_start = self.position
    const spec_line = self.line
    const frame_idx = self.interp_stack.len - 1
    while self.position < text.len and text[self.position] != '}' and text[self.position] != '"' {
        if text[self.position] == '\n' { self.line = self.line + 1 }
        self.position = self.position + 1
    }
    if self.position >= text.len or text[self.position] == '"' {
        while self.interp_stack.len > 0 { self.interp_stack.pop() }
        return Token {
            kind = TokenKind.BadToken,
            text = text[spec_start..self.position],
            offset = spec_start,
            line = spec_line,
            leading = empty_trivia(),
            trailing = empty_trivia(),
            allocator = self.allocator,
        }
    }

    const spec_text = text[spec_start..self.position]
    const close_start = self.position
    const close_line = self.line
    self.position = self.position + 1
    self.interp_stack[frame_idx].in_format_spec = false
    self.interp_stack[frame_idx].in_segment = true
    const hole_end = Token {
        kind = TokenKind.InterpHoleEnd,
        text = text[close_start..self.position],
        offset = close_start,
        line = close_line,
        leading = empty_trivia(),
        trailing = empty_trivia(),
        allocator = self.allocator,
    }
    queue_token(self, hole_end)
    return Token {
        kind = TokenKind.InterpFormatSpec,
        text = spec_text,
        offset = spec_start,
        line = spec_line,
        leading = empty_trivia(),
        trailing = empty_trivia(),
        allocator = self.allocator,
    }
}

// Track bracket depths inside a hole. Returns the rewritten kind when
// the token is intercepted (un-matched `}` → InterpHoleEnd, unbracketed
// `:` → InterpFormatSep), null otherwise. Caller skips trailing trivia
// on intercepted tokens.
fn adjust_for_hole_mode(self: &Lexer, kind: TokenKind, frame_idx: usize) TokenKind? {
    if kind == TokenKind.OpenBrace {
        self.interp_stack[frame_idx].brace_depth = self.interp_stack[frame_idx].brace_depth + 1
        return null
    }
    if kind == TokenKind.OpenParenthesis {
        self.interp_stack[frame_idx].paren_depth = self.interp_stack[frame_idx].paren_depth + 1
        return null
    }
    if kind == TokenKind.OpenBracket {
        self.interp_stack[frame_idx].bracket_depth = self.interp_stack[frame_idx].bracket_depth + 1
        return null
    }
    if kind == TokenKind.CloseBrace {
        if self.interp_stack[frame_idx].brace_depth == 0 {
            self.interp_stack[frame_idx].in_segment = true
            return TokenKind.InterpHoleEnd
        }
        self.interp_stack[frame_idx].brace_depth = self.interp_stack[frame_idx].brace_depth - 1
        return null
    }
    if kind == TokenKind.CloseParenthesis {
        if self.interp_stack[frame_idx].paren_depth > 0 {
            self.interp_stack[frame_idx].paren_depth = self.interp_stack[frame_idx].paren_depth - 1
        }
        return null
    }
    if kind == TokenKind.CloseBracket {
        if self.interp_stack[frame_idx].bracket_depth > 0 {
            self.interp_stack[frame_idx].bracket_depth = self.interp_stack[frame_idx].bracket_depth - 1
        }
        return null
    }
    if kind == TokenKind.Colon {
        if self.interp_stack[frame_idx].brace_depth == 0
            and self.interp_stack[frame_idx].paren_depth == 0
            and self.interp_stack[frame_idx].bracket_depth == 0 {
            self.interp_stack[frame_idx].in_format_spec = true
            return TokenKind.InterpFormatSep
        }
        return null
    }
    return null
}

fn queue_token(self: &Lexer, tok: Token) {
    self.has_pending = true
    self.pending_token = tok
}

fn empty_token(allocator: &Allocator) Token {
    return Token {
        kind = TokenKind.Eof,
        text = "",
        offset = 0,
        line = 0,
        leading = empty_trivia(),
        trailing = empty_trivia(),
        allocator = allocator,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Literal decoders — CST holds raw source slices; AST projection calls
// these to materialise the runtime value of a literal.
// ─────────────────────────────────────────────────────────────────────────

// Materialise a `"..."` literal's runtime byte value: strip the quotes
// and expand every escape (`\n`, `\t`, `\r`, `\\`, `\"`, `\'`, `\0`,
// and `\uXXXX` UTF-8-encoded). `raw` must be the full lexed slice
// including both quote characters; pass `Token.text` directly.
//
// Returns `null` on:
//   - missing or mismatched outer quotes
//   - `\u` with no hex digits, more than 6 digits, or codepoint > 0x10FFFF
// The same conditions cause the lexer to mark the token `BadToken`,
// so well-formed `StringLiteral` tokens always decode to `Some`.
//
// The returned `OwnedString` owns its buffer — caller must `.deinit()`.
// `allocator` backs that buffer; pass `null` to default to the global
// allocator (or the test allocator under test).
pub fn decode_string_literal(raw: String, allocator: &Allocator? = null) OwnedString? {
    if raw.len < 2 { return null }
    if raw[0] != '"' or raw[raw.len - 1] != '"' { return null }
    return decode_quoted_run(raw, 1, raw.len - 1, allocator)
}

// Materialise a `'c'` or `b'c'` literal to its codepoint (char) or
// byte value. `raw` must be the full lexed slice including the
// quotes (and the leading `b` for byte literals); pass `Token.text`
// directly.
//
// Returns `null` on:
//   - missing/mismatched quotes or empty payload
//   - more than one character in the payload
//   - `\uXXXX` codepoint > 0x10FFFF
//   - `\u` inside a byte literal (always rejected)
//   - byte-literal value > 255
//   - malformed UTF-8 in the payload
// These match the lexer's BadToken conditions, so well-formed
// `CharLiteral` / `ByteLiteral` tokens always decode to `Some`.
pub fn decode_char_literal(raw: String) u32? {
    if raw.len < 3 { return null }
    let inner_start = 1usize
    let kind_is_byte = false
    if raw[0] == 'b' {
        kind_is_byte = true
        if raw[1] != '\'' { return null }
        inner_start = 2
    } else if raw[0] != '\'' {
        return null
    }
    if raw[raw.len - 1] != '\'' { return null }
    if inner_start >= raw.len - 1 { return null }

    let i = inner_start
    let cp: u32 = 0
    if raw[i] == '\\' {
        if i + 1 >= raw.len - 1 { return null }
        const esc = raw[i + 1]
        if esc == 'u' {
            if kind_is_byte { return null }
            let j = i + 2
            let value: u32 = 0
            let count = 0usize
            while j < raw.len - 1 and is_hex_digit(raw[j]) and count < 6 {
                value = value * 16 + (hex_digit_value(raw[j]) as u32)
                j = j + 1
                count = count + 1
            }
            if count == 0 or value > 0x10FFFF { return null }
            if j != raw.len - 1 { return null }
            cp = value
        } else {
            cp = decode_simple_escape(esc) as u32
            if i + 2 != raw.len - 1 { return null }
        }
    } else {
        const first = raw[i]
        let extra = 0usize
        if first >= 0xF0 { extra = 3 }
        else if first >= 0xE0 { extra = 2 }
        else if first >= 0xC0 { extra = 1 }
        if i + 1 + extra != raw.len - 1 { return null }
        cp = first as u32
        let k = 0usize
        while k < extra {
            const cont = raw[i + 1 + k]
            const masked = cont & 0xC0
            if masked != 0x80 { return null }
            const lower = (cont & 0x3F) as u32
            cp = (cp << 6) | lower
            k = k + 1
        }
        if extra == 1 {
            cp = cp & 0x07FF
        } else if extra == 2 {
            cp = cp & 0xFFFF
        } else if extra == 3 {
            cp = cp & 0x1FFFFF
        }
    }

    if kind_is_byte and cp > 255 { return null }
    if cp > 0x10FFFF { return null }
    return cp
}

// Materialise an `InterpSegment` token's runtime bytes. Same escape
// vocabulary as `decode_string_literal`, plus segment-only `{{` and
// `}}` doubling that decode to a single `{` / `}`. `raw` is the
// segment text exactly as the lexer captured it (no quotes — segments
// have no surrounding delimiters).
//
// Returns `null` on a malformed `\uXXXX` escape; otherwise the
// caller-owned decoded buffer. `allocator` backs that buffer; pass
// `null` to default to the global allocator.
pub fn decode_interp_segment(raw: String, allocator: &Allocator? = null) OwnedString? {
    let sb = string_builder(raw.len, allocator)
    let i = 0usize
    while i < raw.len {
        const c = raw[i]
        const is_brace = c == '{' or c == '}'
        if is_brace and i + 1 < raw.len and raw[i + 1] == c {
            sb.append_byte(c)
            i = i + 2
            continue
        }
        if c == '\\' and i + 1 < raw.len {
            const esc = raw[i + 1]
            if esc == 'u' {
                if !append_unicode_escape(&sb, raw, i + 2, raw.len) {
                    sb.deinit()
                    return null
                }
                i = advance_past_unicode_escape(raw, i + 2, raw.len)
                continue
            }
            sb.append_byte(decode_simple_escape(esc))
            i = i + 2
            continue
        }
        sb.append_byte(c)
        i = i + 1
    }
    return sb.to_string()
}

fn decode_quoted_run(raw: String, lo: usize, hi: usize, allocator: &Allocator?) OwnedString? {
    let sb = string_builder(hi - lo, allocator)
    let i = lo
    while i < hi {
        const c = raw[i]
        if c == '\\' and i + 1 < hi {
            const esc = raw[i + 1]
            if esc == 'u' {
                if !append_unicode_escape(&sb, raw, i + 2, hi) {
                    sb.deinit()
                    return null
                }
                i = advance_past_unicode_escape(raw, i + 2, hi)
                continue
            }
            sb.append_byte(decode_simple_escape(esc))
            i = i + 2
            continue
        }
        sb.append_byte(c)
        i = i + 1
    }
    return sb.to_string()
}

fn append_unicode_escape(sb: &StringBuilder, raw: String, lo: usize, hi: usize) bool {
    let j = lo
    let value: u32 = 0
    let count = 0usize
    while j < hi and is_hex_digit(raw[j]) and count < 6 {
        value = value * 16 + (hex_digit_value(raw[j]) as u32)
        j = j + 1
        count = count + 1
    }
    if count == 0 or value > 0x10FFFF { return false }
    let buf = [0u8; 4]
    const n = encode_char(value as char, buf as u8[])
    let k = 0usize
    while k < n {
        sb.append_byte(buf[k])
        k = k + 1
    }
    return true
}

fn advance_past_unicode_escape(raw: String, lo: usize, hi: usize) usize {
    let j = lo
    let count = 0usize
    while j < hi and is_hex_digit(raw[j]) and count < 6 {
        j = j + 1
        count = count + 1
    }
    return j
}
