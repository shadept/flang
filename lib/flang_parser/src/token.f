// Token - the lexer's output unit, carrying its own trivia.
//
// Every byte of the source belongs to exactly one Token's leading trivia, text, or trailing trivia.
// The lexer never drops whitespace or comments - they're attached to the nearest token so the CST
// can round-trip to source byte-for-byte. See trivia.f for the trivia model.

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

// A lexer-produced token - 32 bytes, owning nothing.
//
// `text` is a view into the source buffer covering exactly the token's bytes; `offset` is where
// those bytes start. That pair is the whole token: everything else a token could say about itself
// is a function of the source and the offsets, so it is derived rather than stored.
//
// Trivia (the whitespace and comments bordering the token) used to live here as two owned slices
// plus the allocator to free them - 40 of the token's 80 bytes, and a heap allocation per token,
// for views into a buffer that is kept alive anyway. Every byte between one token's text and the
// next IS trivia by construction, so `trivia.f` walks it on demand: `trivia_in`, bounded by
// `leading_end` / `trailing_end`. The losslessness invariant is unchanged - concatenating leading +
// text + trailing across every token in order still reproduces the source exactly - it is just no
// longer materialised.
//
// `line` is gone the same way. Callers that need a line number either count newlines as they walk
// (the formatter, folding ranges) or ask a `LineIndex`, which the diagnostic path builds anyway.
pub type Token = struct {
    kind: TokenKind
    text: String
    offset: usize
}

// True for any keyword token - useful for syntax highlighting and the formatter's word-spacing
// rules.
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
