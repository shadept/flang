using System.Text;
using FLang.Core;

namespace FLang.Frontend;

/// <summary>
/// Lexical analyzer that tokenizes FLang source code into a stream of tokens.
/// </summary>
/// <remarks>
/// Initializes a new instance of the <see cref="Lexer"/> class.
/// </remarks>
/// <param name="source">The source code to tokenize.</param>
/// <param name="fileId">The unique identifier for the source file.</param>
public class Lexer(Source source, int fileId)
{
    private readonly int _fileId = fileId;
    private readonly Source _source = source;
    private int _position;
    private int _start;


    /// <summary>
    /// Advances the lexer to the next token in the source stream.
    /// Skips whitespace and single-line comments automatically.
    /// </summary>
    /// <returns>The next token from the source code, or an EndOfFile token if the end is reached.</returns>
    public Token NextToken()
    {
        var text = _source.Text.AsSpan();
        char ch;

        // Skip all whitespace and single-line comments up-front
        while (_position < text.Length)
        {
            ch = text[_position];

            // Eat whitespace
            if (char.IsWhiteSpace(ch))
            {
                _position++;
                continue;
            }

            // Skip single-line comments starting with //
            if (ch == '/' && _position + 1 < text.Length && text[_position + 1] == '/')
            {
                _position += 2; // Skip the "//"
                while (_position < text.Length && text[_position] != '\n') _position++;
                if (_position < text.Length)
                    _position++; // Skip the newline character
                continue; // Keep scanning for the next meaningful character
            }

            break; // Non-whitespace, non-comment character found
        }

        if (_position >= text.Length)
        {
            _start = _position;
            return CreateToken(TokenKind.EndOfFile);
        }

        ch = text[_position];

        if (char.IsDigit(ch))
        {
            _start = _position;
            bool isFloat = false;

            // Check for hex literal (0x or 0X prefix)
            bool isHex = ch == '0' && _position + 1 < text.Length && (text[_position + 1] == 'x' || text[_position + 1] == 'X');
            if (isHex)
            {
                _position += 2; // Skip "0x"
                while (_position < text.Length && (IsHexDigit(text[_position]) || text[_position] == '_'))
                    _position++;
            }
            else
            {
                while (_position < text.Length && (char.IsDigit(text[_position]) || text[_position] == '_'))
                    _position++;

                // Check for decimal point: '.' followed by a digit (not '..' range or '.method()')
                if (_position < text.Length && text[_position] == '.'
                    && _position + 1 < text.Length && char.IsDigit(text[_position + 1]))
                {
                    isFloat = true;
                    _position++; // skip '.'
                    while (_position < text.Length && (char.IsDigit(text[_position]) || text[_position] == '_'))
                        _position++;
                }

                // Check for scientific notation: e/E followed by optional +/- and digits
                if (_position < text.Length && (text[_position] == 'e' || text[_position] == 'E'))
                {
                    isFloat = true;
                    _position++; // skip 'e'/'E'
                    if (_position < text.Length && (text[_position] == '+' || text[_position] == '-'))
                        _position++; // skip sign
                    while (_position < text.Length && (char.IsDigit(text[_position]) || text[_position] == '_'))
                        _position++;
                }

                // Check for f32/f64 suffix
                if (_position < text.Length && text[_position] == 'f'
                    && _position + 1 < text.Length && (text[_position + 1] == '3' || text[_position + 1] == '6'))
                {
                    var suffixStart = _position;
                    _position += 2; // skip 'f3' or 'f6'
                    if (_position < text.Length && char.IsDigit(text[_position]))
                        _position++; // skip the '2' in f32 or '4' in f64
                    var suffix = text[suffixStart.._position];
                    if (suffix is "f32" or "f64")
                    {
                        isFloat = true;
                    }
                    else
                    {
                        _position = suffixStart; // backtrack
                    }
                }
            }

            if (isFloat)
                return CreateToken(TokenKind.Float);

            // Check for integer type suffix (e.g., 42u8, 100isize)
            if (!isHex && _position < text.Length && (text[_position] == 'i' || text[_position] == 'u'))
            {
                var suffixStart = _position;
                while (_position < text.Length && char.IsLetterOrDigit(text[_position]))
                    _position++;
                var suffix = text[suffixStart.._position];
                if (suffix is not ("i8" or "i16" or "i32" or "i64" or "isize"
                    or "u8" or "u16" or "u32" or "u64" or "usize"))
                    _position = suffixStart; // backtrack if not a valid suffix
            }

            return CreateToken(TokenKind.Integer);
        }

        if (ch == '"')
        {
            _start = _position;
            _position++; // Skip opening quote

            var stringBuilder = new StringBuilder();

            while (_position < text.Length && text[_position] != '"')
                if (text[_position] == '\\' && _position + 1 < text.Length)
                {
                    _position++;
                    var escapeChar = text[_position];
                    if (escapeChar == 'u')
                    {
                        // Unicode escape: \uXXXX (1-6 hex digits)
                        _position++;
                        var codepoint = ReadUnicodeEscape(text);
                        if (codepoint < 0)
                            return CreateTokenWithValue(TokenKind.BadToken, "");
                        stringBuilder.Append(char.ConvertFromUtf32(codepoint));
                    }
                    else
                    {
                        var escaped = escapeChar switch
                        {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '\\' => '\\',
                            '"' => '"',
                            '0' => '\0',
                            _ => escapeChar // Unknown escape, keep as-is
                        };
                        stringBuilder.Append(escaped);
                        _position++;
                    }
                }
                else
                {
                    stringBuilder.Append(text[_position]);
                    _position++;
                }

            if (_position >= text.Length)
                // Unterminated string literal
                return CreateTokenWithValue(TokenKind.BadToken, "");

            _position++; // Skip closing quote
            return CreateTokenWithValue(TokenKind.StringLiteral, stringBuilder.ToString());
        }

        if (ch == '\'')
        {
            return LexCharLiteral(text, TokenKind.CharLiteral);
        }

        if (char.IsLetter(ch) || ch == '_')
        {
            // Check for byte literal: b'...'
            if (ch == 'b' && _position + 1 < text.Length && text[_position + 1] == '\'')
            {
                _start = _position;
                _position++; // Skip 'b'
                return LexCharLiteral(text, TokenKind.ByteLiteral);
            }

            _start = _position;
            while (_position < text.Length && (char.IsLetterOrDigit(text[_position]) || text[_position] == '_'))
                _position++;

            var span = text[_start.._position];

            var kind = span switch
            {
                "pub" => TokenKind.Pub,
                "fn" => TokenKind.Fn,
                "return" => TokenKind.Return,
                "let" => TokenKind.Let,
                "const" => TokenKind.Const,
                "if" => TokenKind.If,
                "else" => TokenKind.Else,
                "for" => TokenKind.For,
                "loop" => TokenKind.Loop,
                "in" => TokenKind.In,
                "break" => TokenKind.Break,
                "continue" => TokenKind.Continue,
                "defer" => TokenKind.Defer,
                "import" => TokenKind.Import,
                "struct" => TokenKind.Struct,
                "enum" => TokenKind.Enum,
                "match" => TokenKind.Match,
                "as" => TokenKind.As,
                "test" => TokenKind.Test,
                "type" => TokenKind.Type,
                "and" => TokenKind.And,
                "or" => TokenKind.Or,
                "true" => TokenKind.True,
                "false" => TokenKind.False,
                "null" => TokenKind.Null,
                "_" => TokenKind.Underscore,
                _ => TokenKind.Identifier
            };

            return CreateToken(kind);
        }

        // Whitespace already skipped at the top

        // Check for three-character operators first
        if (_position + 2 < text.Length)
        {
            _start = _position;
            if (ch == '>' && text[_position + 1] == '>' && text[_position + 2] == '>')
            {
                _position += 3;
                return CreateToken(TokenKind.UnsignedShiftRight);
            }
        }

        // Check for two-character operators
        if (_position + 1 < text.Length)
        {
            var next = text[_position + 1];
            _start = _position;

            var twoCharToken = (c: ch, next) switch
            {
                ('.', '.') => TokenKind.DotDot,
                ('=', '=') => TokenKind.EqualsEquals,
                ('=', '>') => TokenKind.FatArrow,
                ('!', '=') => TokenKind.NotEquals,
                ('<', '<') => TokenKind.ShiftLeft,
                ('<', '=') => TokenKind.LessThanOrEqual,
                ('>', '>') => TokenKind.ShiftRight,
                ('>', '=') => TokenKind.GreaterThanOrEqual,
                ('?', '?') => TokenKind.QuestionQuestion,
                ('?', '.') => TokenKind.QuestionDot,
                _ => (TokenKind?)null
            };

            if (twoCharToken.HasValue)
            {
                _position += 2;
                return CreateToken(twoCharToken.Value);
            }
        }

        _start = _position;
        _position++;

        return ch switch
        {
            '(' => CreateToken(TokenKind.OpenParenthesis),
            ')' => CreateToken(TokenKind.CloseParenthesis),
            '{' => CreateToken(TokenKind.OpenBrace),
            '}' => CreateToken(TokenKind.CloseBrace),
            '[' => CreateToken(TokenKind.OpenBracket),
            ']' => CreateToken(TokenKind.CloseBracket),
            ':' => CreateToken(TokenKind.Colon),
            '=' => CreateToken(TokenKind.Equals),
            ';' => CreateToken(TokenKind.Semicolon),
            ',' => CreateToken(TokenKind.Comma),
            '&' => CreateToken(TokenKind.Ampersand),
            '|' => CreateToken(TokenKind.Pipe),
            '^' => CreateToken(TokenKind.Caret),
            '?' => CreateToken(TokenKind.Question),
            '+' => CreateToken(TokenKind.Plus),
            '-' => CreateToken(TokenKind.Minus),
            '*' => CreateToken(TokenKind.Star),
            '/' => CreateToken(TokenKind.Slash),
            '%' => CreateToken(TokenKind.Percent),
            '<' => CreateToken(TokenKind.LessThan),
            '>' => CreateToken(TokenKind.GreaterThan),
            '.' => CreateToken(TokenKind.Dot),
            '#' => CreateToken(TokenKind.Hash),
            '$' => CreateToken(TokenKind.Dollar),
            '!' => CreateToken(TokenKind.Bang),
            _ => CreateToken(TokenKind.BadToken)
        };
    }

    /// <summary>
    /// Creates a source span representing the current token's location in the source file.
    /// </summary>
    /// <returns>A <see cref="SourceSpan"/> covering the range from _start to _position.</returns>
    private SourceSpan CreateSpan()
    {
        return new SourceSpan(_fileId, _start, _position - _start);
    }

    /// <summary>
    /// Peeks at the next token without consuming it from the stream.
    /// The lexer's internal state is preserved after this operation.
    /// </summary>
    /// <returns>The next token that would be returned by <see cref="NextToken"/>.</returns>
    public Token PeekNextToken()
    {
        // Save current state
        var savedPosition = _position;
        var savedStart = _start;

        // Get next token
        var token = NextToken();

        // Restore state
        _position = savedPosition;
        _start = savedStart;

        return token;
    }

    /// <summary>
    /// Creates a token of the specified kind using the current lexer position.
    /// The token's text is extracted from the source between _start and _position.
    /// </summary>
    /// <param name="kind">The kind of token to create.</param>
    /// <returns>A new <see cref="Token"/> with the specified kind and extracted text.</returns>
    private Token CreateToken(TokenKind kind)
    {
        var text = _position > _start ? _source.Text.AsSpan()[_start.._position].ToString() : "";
        return new Token(kind, CreateSpan(), text);
    }

    /// <summary>
    /// Creates a token with a custom value, typically used for string literals where
    /// the value differs from the raw source text (e.g., after escape sequence processing).
    /// </summary>
    /// <param name="kind">The kind of token to create.</param>
    /// <param name="value">The processed value to store in the token.</param>
    /// <returns>A new <see cref="Token"/> with the specified kind and custom value.</returns>
    private Token CreateTokenWithValue(TokenKind kind, string value)
    {
        return new Token(kind, CreateSpan(), value);
    }

    /// <summary>
    /// Lexes a char literal ('x') or byte literal (b'x'). Position should be at the opening quote.
    /// </summary>
    private Token LexCharLiteral(ReadOnlySpan<char> text, TokenKind kind)
    {
        _position++; // Skip opening quote

        if (_position >= text.Length || text[_position] == '\'')
        {
            // Empty char literal
            if (_position < text.Length) _position++; // Skip closing quote
            return CreateTokenWithValue(TokenKind.BadToken, "");
        }

        int codepoint;
        if (text[_position] == '\\' && _position + 1 < text.Length)
        {
            _position++;
            var escapeChar = text[_position];
            if (escapeChar == 'u')
            {
                if (kind == TokenKind.ByteLiteral)
                {
                    // \u not allowed in byte literals
                    return CreateTokenWithValue(TokenKind.BadToken, "");
                }
                _position++;
                codepoint = ReadUnicodeEscape(text);
                if (codepoint < 0)
                    return CreateTokenWithValue(TokenKind.BadToken, "");
            }
            else
            {
                codepoint = escapeChar switch
                {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '\'' => '\'',
                    '0' => '\0',
                    _ => escapeChar
                };
                _position++;
            }
        }
        else
        {
            var ch0 = text[_position];
            if (char.IsHighSurrogate(ch0) && _position + 1 < text.Length && char.IsLowSurrogate(text[_position + 1]))
            {
                codepoint = char.ConvertToUtf32(ch0, text[_position + 1]);
                _position += 2;
            }
            else
            {
                codepoint = ch0;
                _position++;
            }
        }

        if (_position >= text.Length || text[_position] != '\'')
        {
            // Unterminated or multi-character literal
            return CreateTokenWithValue(TokenKind.BadToken, "");
        }

        _position++; // Skip closing quote

        if (kind == TokenKind.ByteLiteral && codepoint > 255)
        {
            return CreateTokenWithValue(TokenKind.BadToken, "");
        }

        return CreateTokenWithValue(kind, codepoint.ToString());
    }

    /// <summary>
    /// Reads a unicode escape sequence (1-6 hex digits after \u). Returns the codepoint, or -1 on error.
    /// Position should be right after the 'u'.
    /// </summary>
    private int ReadUnicodeEscape(ReadOnlySpan<char> text)
    {
        var hexStart = _position;
        while (_position < text.Length && IsHexDigit(text[_position]) && (_position - hexStart) < 6)
            _position++;

        if (_position == hexStart)
            return -1; // No hex digits

        var hexSpan = text[hexStart.._position];
        var codepoint = int.Parse(hexSpan, System.Globalization.NumberStyles.HexNumber);

        if (codepoint > 0x10FFFF)
            return -1; // Invalid codepoint

        return codepoint;
    }

    /// <summary>
    /// Checks if a character is a valid hexadecimal digit (0-9, a-f, A-F).
    /// </summary>
    private static bool IsHexDigit(char c)
    {
        return char.IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
}
