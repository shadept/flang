using System.Text;
using FLang.Core;

namespace FLang.Frontend;

public class Lexer
{
    private readonly int _fileId;
    private readonly Source _source;
    private int _position;
    private int _start;

    public Lexer(Source source, int fileId)
    {
        _source = source;
        _fileId = fileId;
    }

    public Token NextToken()
    {
        var text = _source.Text.AsSpan();

        if (_position >= text.Length)
        {
            _start = _position;
            return CreateToken(TokenKind.EndOfFile);
        }

        // Skip comments
        if (text[_position] == '/')
            if (_position + 1 < text.Length && text[_position + 1] == '/')
            {
                // This is a single-line comment (either // or //!)
                _position += 2; // Skip the "//"
                while (_position < text.Length && text[_position] != '\n') _position++;
                if (_position < text.Length)
                    _position++; // Skip the newline character
                return NextToken(); // Get the next token after the comment
            }

        var c = text[_position];

        if (char.IsDigit(c))
        {
            _start = _position;
            while (_position < text.Length && char.IsDigit(text[_position]))
                _position++;
            return CreateToken(TokenKind.Integer);
        }

        if (c == '"')
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

        if (char.IsLetter(c))
        {
            _start = _position;
            while (_position < text.Length && char.IsLetterOrDigit(text[_position]))
                _position++;

            var span = text.Slice(_start, _position - _start);

            var kind = span switch
            {
                "pub" => TokenKind.Pub,
                "fn" => TokenKind.Fn,
                "return" => TokenKind.Return,
                "let" => TokenKind.Let,
                "if" => TokenKind.If,
                "else" => TokenKind.Else,
                "for" => TokenKind.For,
                "in" => TokenKind.In,
                "break" => TokenKind.Break,
                "continue" => TokenKind.Continue,
                "import" => TokenKind.Import,
                "struct" => TokenKind.Struct,
                "foreign" => TokenKind.Foreign,
                "true" => TokenKind.True,
                "false" => TokenKind.False,
                _ => TokenKind.Identifier
            };

            return CreateToken(kind);
        }

        if (char.IsWhiteSpace(c))
        {
            _position++;
            return NextToken();
        }

        // Check for two-character operators
        if (_position + 1 < text.Length)
        {
            var next = text[_position + 1];
            _start = _position;

            var twoCharToken = (c, next) switch
            {
                ('.', '.') => TokenKind.DotDot,
                ('=', '=') => TokenKind.EqualsEquals,
                ('!', '=') => TokenKind.NotEquals,
                ('<', '=') => TokenKind.LessThanOrEqual,
                ('>', '=') => TokenKind.GreaterThanOrEqual,
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

        return c switch
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
            _ => CreateToken(TokenKind.BadToken)
        };
    }

    private SourceSpan CreateSpan()
    {
        return new SourceSpan(_fileId, _start, _position - _start);
    }

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

    private Token CreateToken(TokenKind kind)
    {
        var text = _position > _start
            ? _source.Text.AsSpan().Slice(_start, _position - _start).ToString()
            : "";
        return new Token(kind, CreateSpan(), text);
    }

    private Token CreateTokenWithValue(TokenKind kind, string value)
    {
        return new Token(kind, CreateSpan(), value);
    }
}