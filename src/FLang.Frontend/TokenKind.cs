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
    Const,
    If,
    Else,
    For,
    In,
    Break,
    Continue,
    Defer,
    Import,
    Struct,
    Enum,
    Match,
    Foreign,
    As,
    Test,

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
    QuestionQuestion,
    QuestionDot,
    FatArrow,
    Bang,

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
    Underscore,

    // Identifier
    Identifier
}
