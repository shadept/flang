using System.Text;
using FLang.Core;

namespace FLang.Frontend;

/// <summary>
/// Lexical analyzer that tokenizes FLang source code into a stream of tokens.
/// </summary>
public class Lexer
{
    private readonly int _fileId;
    private readonly Source _source;
    private int _position;
    private int _start;

    /// <summary>
    /// Initializes a new instance of the <see cref="Lexer"/> class.
    /// </summary>
    /// <param name="source">The source code to tokenize.</param>
    /// <param name="fileId">The unique identifier for the source file.</param>
    public Lexer(Source source, int fileId)
    {
        _source = source;
        _fileId = fileId;
    }

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
            while (_position < text.Length && char.IsDigit(text[_position]))
                _position++;
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
                    // Handle escape sequences
                    _position++;
                    var escapeChar = text[_position];
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

        if (char.IsLetter(ch) || ch == '_')
        {
            _start = _position;
            while (_position < text.Length && (char.IsLetterOrDigit(text[_position]) || text[_position] == '_'))
                _position++;

            var span = text.Slice(_start, _position - _start);

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
                "in" => TokenKind.In,
                "break" => TokenKind.Break,
                "continue" => TokenKind.Continue,
                "defer" => TokenKind.Defer,
                "import" => TokenKind.Import,
                "struct" => TokenKind.Struct,
                "enum" => TokenKind.Enum,
                "match" => TokenKind.Match,
                "foreign" => TokenKind.Foreign,
                "as" => TokenKind.As,
                "test" => TokenKind.Test,
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
                ('<', '=') => TokenKind.LessThanOrEqual,
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
        var text = _position > _start
            ? _source.Text.AsSpan().Slice(_start, _position - _start).ToString()
            : "";
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
}
