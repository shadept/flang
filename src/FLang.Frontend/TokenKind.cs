namespace FLang.Frontend;

public enum TokenKind
{
    // Special
    EndOfFile,
    BadToken,

    // Literals
    Integer,
    StringLiteral,
    CharLiteral,
    ByteLiteral,
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
    Loop,
    In,
    Break,
    Continue,
    Defer,
    Import,
    Struct,
    Enum,
    Match,
    As,
    Test,
    And,
    Or,

    // Operators
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Dot,
    DotDot,
    Ampersand,
    Pipe,
    Caret,
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

    // Shift operators
    ShiftLeft,
    ShiftRight,
    UnsignedShiftRight,

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
