namespace FLang.Frontend;

public enum TokenKind
{
    // Special
    EndOfFile,
    BadToken,

    // Literals
    Integer,
    StringLiteral,
    True,
    False,
    Null,

    // Keywords
    Pub,
    Fn,
    Return,
    Let,
    If,
    Else,
    For,
    In,
    Break,
    Continue,
    Defer,
    Import,
    Struct,
    Foreign,
    As,

    // Operators
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Dot,
    DotDot,
    Ampersand,
    Question,

    // Comparison operators
    EqualsEquals,
    NotEquals,
    LessThan,
    GreaterThan,
    LessThanOrEqual,
    GreaterThanOrEqual,

    // Punctuation
    OpenParenthesis,
    CloseParenthesis,
    OpenBrace,
    CloseBrace,
    OpenBracket,
    CloseBracket,
    Colon,
    Equals,
    Semicolon,
    Hash,
    Comma,
    Dollar,

    // Identifier
    Identifier
}