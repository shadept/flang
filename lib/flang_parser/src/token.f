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
    Move

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
    return kind match {
        TokenKind.Pub => true
        TokenKind.Fn => true
        TokenKind.Return => true
        TokenKind.Let => true
        TokenKind.Const => true
        TokenKind.If => true
        TokenKind.Else => true
        TokenKind.For => true
        TokenKind.Loop => true
        TokenKind.While => true
        TokenKind.In => true
        TokenKind.Break => true
        TokenKind.Continue => true
        TokenKind.Defer => true
        TokenKind.Import => true
        TokenKind.Struct => true
        TokenKind.Enum => true
        TokenKind.Match => true
        TokenKind.As => true
        TokenKind.Test => true
        TokenKind.Type => true
        TokenKind.And => true
        TokenKind.Or => true
        TokenKind.Move => true
        TokenKind.True => true
        TokenKind.False => true
        TokenKind.Null => true
        else => false
    }
}
