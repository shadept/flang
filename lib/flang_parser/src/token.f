// Token — the lexer's output unit, carrying its own trivia.
//
// Every byte of the source belongs to exactly one Token's leading trivia,
// text, or trailing trivia. The lexer never drops whitespace or comments —
// they're attached to the nearest token so the CST can round-trip to source
// byte-for-byte. See trivia.f for the trivia model.

import std.allocator
import std.enum
import std.list
import flang_parser.trivia

// All token kinds the FLang lexer can produce.
pub type TokenKind = enum {
    // ─────────────────────────────────────────────────────────────────────
    // Special
    // ─────────────────────────────────────────────────────────────────────

    // Sentinel emitted at end of file.
    Eof
    // Unrecognized byte sequence; `Token.text` carries the offending span.
    BadToken

    // ─────────────────────────────────────────────────────────────────────
    // Literals
    // ─────────────────────────────────────────────────────────────────────

    Integer
    Float
    StringLiteral
    CharLiteral
    ByteLiteral
    True
    False
    Null

    // ─────────────────────────────────────────────────────────────────────
    // Keywords — order matches `TokenKindExtensions.IsKeyword` in stage-0.
    // ─────────────────────────────────────────────────────────────────────

    Pub
    Fn
    Return
    Let
    Const
    If
    Else
    For
    Loop
    While
    In
    Break
    Continue
    Defer
    Import
    Struct
    Enum
    Match
    As
    Test
    Type
    And
    Or

    // ─────────────────────────────────────────────────────────────────────
    // Operators
    // ─────────────────────────────────────────────────────────────────────

    Plus
    Minus
    Star
    Slash
    Percent
    Dot
    DotDot
    DotDotEquals
    Ampersand
    Pipe
    Caret
    Question
    QuestionQuestion
    QuestionDot
    FatArrow
    Bang
    Tilde

    // Comparison
    EqualsEquals
    NotEquals
    LessThan
    GreaterThan
    LessThanOrEqual
    GreaterThanOrEqual

    // Shift
    ShiftLeft
    ShiftRight
    UnsignedShiftRight

    // ─────────────────────────────────────────────────────────────────────
    // Punctuation
    // ─────────────────────────────────────────────────────────────────────

    OpenParenthesis
    CloseParenthesis
    OpenBrace
    CloseBrace
    OpenBracket
    CloseBracket
    Colon
    Equals
    Semicolon
    Hash
    Comma
    Dollar
    Underscore

    // ─────────────────────────────────────────────────────────────────────
    // Identifier
    // ─────────────────────────────────────────────────────────────────────

    Identifier

    // ─────────────────────────────────────────────────────────────────────
    // Interpolated string tokens (RFC-004).
    //
    // Interpolation produces a structured token stream: `$"a{b}c"` lexes as
    // InterpStringStart, InterpSegment("a"), InterpHoleStart, Identifier("b"),
    // InterpHoleEnd, InterpSegment("c"), InterpStringEnd. Format specs use
    // InterpFormatSep + InterpFormatSpec inside the hole.
    // ─────────────────────────────────────────────────────────────────────

    InterpStringStart
    InterpSegment
    InterpHoleStart
    InterpHoleEnd
    InterpFormatSep
    InterpFormatSpec
    InterpStringEnd
}

#enum_utils(TokenKind)

// A lexer-produced token. `text` is a view into the source buffer covering
// exactly the token's bytes — no leading/trailing trivia. `leading` and
// `trailing` carry the whitespace and comments that border this token; the
// invariant is that concatenating `t.leading + t.text + t.trailing` across
// every token in order reproduces the source file exactly.
//
// `offset` is the byte offset of `text` from the start of the source.
// `line` is the 0-based line of `text`'s first byte — newlines inside
// the token's own bytes advance the lexer's cursor but do not change
// this token's `line`. Column is derived on demand from a line-endings
// table on the source.
//
// `leading` and `trailing` are owned, shrunk-to-fit slices produced by
// `List.to_owned_slice` at lex time — there is no excess capacity per
// token. Both slices share `allocator` (every trivia list a Token
// produces comes from the same Lexer), so it lives once on the Token.
pub type Token = struct {
    kind: TokenKind
    text: String
    offset: usize
    line: usize
    leading: Trivia[]
    trailing: Trivia[]
    allocator: &Allocator
}

// Free the trivia slices owned by this token. Called automatically when
// the enclosing `List(Token)` is deinit'd (List walks its elements and
// invokes `.deinit()` on each). The `text` field is a borrow from the
// source buffer and is not freed; Trivia entries are themselves
// non-owning (their `text` is a borrow), so no per-element deinit is
// needed.
pub fn deinit(self: &Token) {
    self.allocator.free(self.leading)
    self.allocator.free(self.trailing)
}

// True for any keyword token — useful for syntax highlighting and the
// formatter's word-spacing rules.
pub fn is_keyword(kind: TokenKind) bool {
    kind match {
        TokenKind.Pub => return true
        TokenKind.Fn => return true
        TokenKind.Return => return true
        TokenKind.Let => return true
        TokenKind.Const => return true
        TokenKind.If => return true
        TokenKind.Else => return true
        TokenKind.For => return true
        TokenKind.Loop => return true
        TokenKind.While => return true
        TokenKind.In => return true
        TokenKind.Break => return true
        TokenKind.Continue => return true
        TokenKind.Defer => return true
        TokenKind.Import => return true
        TokenKind.Struct => return true
        TokenKind.Enum => return true
        TokenKind.Match => return true
        TokenKind.As => return true
        TokenKind.Test => return true
        TokenKind.Type => return true
        TokenKind.And => return true
        TokenKind.Or => return true
        TokenKind.True => return true
        TokenKind.False => return true
        TokenKind.Null => return true
        else => return false
    }
}
