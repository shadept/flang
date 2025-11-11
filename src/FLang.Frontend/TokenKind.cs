namespace FLang.Frontend;

public enum TokenKind
{
    // Special
    EndOfFile,
    BadToken,

    // Literals
    Integer,
    True,
    False,

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
    Import,
    Struct,
    Foreign,

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

    // Identifier
    Identifier,
}
