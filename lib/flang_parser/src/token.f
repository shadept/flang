// Token - the lexer's output unit.
//
// Every byte of the source belongs to exactly one token's leading trivia, text, or trailing trivia,
// so the CST round-trips to source byte-for-byte. See trivia.f for the trivia model.

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
    // Keywords - order matches `TokenKindExtensions.IsKeyword` in stage-0.
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
    // Interpolation produces a structured token stream: `$"a{b}c"` lexes as InterpStringStart,
    // InterpSegment("a"), InterpHoleStart, Identifier("b"), InterpHoleEnd, InterpSegment("c"),
    // InterpStringEnd. Format specs use InterpFormatSep + InterpFormatSpec inside the hole.
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

// A lexer-produced token, owning nothing.
//
// `text` is a view into the source buffer covering exactly the token's bytes and `offset` is where
// those bytes start. Everything else about a token is a function of the source and those offsets,
// so trivia is walked on demand (`trivia.f`) and line numbers come from a `LineIndex`.
pub type Token = struct {
    kind: TokenKind
    text: String
    offset: usize
}

// True for any keyword token.
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
