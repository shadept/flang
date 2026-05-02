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

    public Source Source => _source;
    private int _position;
    private int _start;
    private int _line;

    // Interpolated string state (RFC-004). Each frame tracks one level of an
    // active `$"..."`. Nested interp strings push new frames.
    private sealed class InterpFrame
    {
        public bool InSegment;      // true = lexing segment text between holes
        public bool InFormatSpec;   // true = lexing raw format-spec text after `:`
        public int BraceDepth;      // `{` depth inside the current hole
        public int ParenDepth;      // `(` depth inside the current hole
        public int BracketDepth;    // `[` depth inside the current hole

        public InterpFrame Clone() => new()
        {
            InSegment = InSegment,
            InFormatSpec = InFormatSpec,
            BraceDepth = BraceDepth,
            ParenDepth = ParenDepth,
            BracketDepth = BracketDepth
        };
    }

    private readonly List<InterpFrame> _interpStack = new();

    // When set, the next `"` begins an interpolated string rather than a normal
    // string literal. Set inline by the lexer on `$"` (no whitespace) and by the
    // parser before eating the prefix token for `$(args)"` / `$ident"` forms.
    private bool _markNextStringInterp;

    // Up to one pending token emitted ahead (e.g. after a segment token we
    // queue the hole-start, or after a format-spec we queue the hole-end).
    private Token? _pendingToken;

    /// <summary>
    /// Signal that the next `"` should start an interpolated string. Called by
    /// the parser immediately before `Eat(...)` of the closing `)` or the
    /// identifier in `$(args)"..."` and `$ident"..."` forms. Cleared on the next
    /// call to <see cref="NextToken"/> whether or not a `"` is actually found.
    /// </summary>
    public void MarkNextStringInterp()
    {
        _markNextStringInterp = true;
    }

    /// <summary>
    /// Advances the lexer to the next token in the source stream.
    /// Skips whitespace and single-line comments automatically.
    /// </summary>
    /// <returns>The next token from the source code, or an EndOfFile token if the end is reached.</returns>
    public Token NextToken()
    {
        // Deliver any queued token first (used to emit two tokens for one
        // source event, e.g. InterpSegment followed by InterpHoleStart).
        if (_pendingToken is not null)
        {
            var pending = _pendingToken;
            _pendingToken = null;
            return pending;
        }

        var text = _source.Text.AsSpan();

        // Dispatch on active interp frame. Segment and format-spec modes have
        // their own scanners; hole mode falls through to normal lexing and
        // post-processes the token to intercept hole-closing `}` and `:`.
        if (_interpStack.Count > 0)
        {
            var topFrame = _interpStack[^1];
            if (topFrame.InSegment) return LexSegment(text, topFrame);
            if (topFrame.InFormatSpec) return LexFormatSpec(text, topFrame);
        }

        // `$"` — the lexer emitted Dollar adjacent to `"`, set the flag, and now
        // needs to begin the interp string. `$(args)"` / `$ident"` — parser has
        // set the flag after eating the prefix. Either way, next char must be
        // `"` with no intervening whitespace; otherwise the flag is discarded
        // and the caller gets a parse error on the mismatched token kinds.
        if (_markNextStringInterp)
        {
            _markNextStringInterp = false;
            if (_position < text.Length && text[_position] == '"')
            {
                return BeginInterpString();
            }
        }

        var baseToken = LexNormalToken(text);

        // In hole mode, track bracket depth and intercept the hole-closing
        // `}` and format-spec-opening `:` before they reach the parser.
        if (_interpStack.Count > 0)
        {
            var frame = _interpStack[^1];
            if (!frame.InSegment && !frame.InFormatSpec)
            {
                return AdjustForHoleMode(baseToken, frame);
            }
        }

        return baseToken;
    }

    private Token LexNormalToken(ReadOnlySpan<char> text)
    {
        char ch;

        // Skip all whitespace and single-line comments up-front
        while (_position < text.Length)
        {
            ch = text[_position];

            // Eat whitespace
            if (char.IsWhiteSpace(ch))
            {
                if (ch == '\n') _line++;
                _position++;
                continue;
            }

            // Skip single-line comments starting with //
            if (ch == '/' && _position + 1 < text.Length && text[_position + 1] == '/')
            {
                _position += 2; // Skip the "//"
                while (_position < text.Length && text[_position] != '\n') _position++;
                if (_position < text.Length)
                {
                    _line++; // Count the newline
                    _position++;
                }
                continue; // Keep scanning for the next meaningful character
            }

            // Reject block comments explicitly (RFC-006 #18: `//` is the only comment form).
            if (ch == '/' && _position + 1 < text.Length && text[_position + 1] == '*')
            {
                _start = _position;
                _position += 2; // skip "/*"
                return CreateTokenWithValue(TokenKind.BadToken, "/*");
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
                    if (text[_position] == '\n') _line++;
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
                "while" => TokenKind.While,
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
            '$' => CreateDollarToken(text),
            '!' => CreateToken(TokenKind.Bang),
            '~' => CreateToken(TokenKind.Tilde),
            _ => CreateToken(TokenKind.BadToken)
        };
    }

    /// <summary>
    /// Creates a source span representing the current token's location in the source file.
    /// </summary>
    /// <returns>A <see cref="SourceSpan"/> covering the range from _start to _position.</returns>
    private SourceSpan CreateSpan()
    {
        return new SourceSpan(_fileId, _start, _position - _start, _line);
    }

    /// <summary>
    /// Peeks at the next token without consuming it from the stream.
    /// The lexer's internal state is preserved after this operation.
    /// </summary>
    /// <returns>The next token that would be returned by <see cref="NextToken"/>.</returns>
    public Token PeekNextToken()
    {
        // Save full state (including interp-mode bookkeeping — NextToken may
        // push/pop frames, set pending tokens, and mutate frame depths).
        var savedPosition = _position;
        var savedStart = _start;
        var savedLine = _line;
        var savedMark = _markNextStringInterp;
        var savedPending = _pendingToken;
        var savedStackDepth = _interpStack.Count;
        var savedFrames = new InterpFrame[savedStackDepth];
        for (var i = 0; i < savedStackDepth; i++)
            savedFrames[i] = _interpStack[i].Clone();

        var token = NextToken();

        _position = savedPosition;
        _start = savedStart;
        _line = savedLine;
        _markNextStringInterp = savedMark;
        _pendingToken = savedPending;
        _interpStack.Clear();
        _interpStack.AddRange(savedFrames);

        return token;
    }

    /// <summary>
    /// Emit the Dollar token and, if the very next character is `"`, set the
    /// interp-start flag so the next NextToken() call enters segment mode.
    /// Strict adjacency (no intervening whitespace) prevents accidental interp
    /// triggering from bare `$` in other contexts.
    /// </summary>
    private Token CreateDollarToken(ReadOnlySpan<char> text)
    {
        var token = CreateToken(TokenKind.Dollar);
        if (_position < text.Length && text[_position] == '"')
        {
            _markNextStringInterp = true;
        }
        return token;
    }

    /// <summary>
    /// Consume the opening `"` of an interpolated string, push a new segment-mode
    /// frame, and return the InterpStringStart token.
    /// </summary>
    private Token BeginInterpString()
    {
        _start = _position;
        _position++; // consume `"`
        _interpStack.Add(new InterpFrame { InSegment = true });
        return CreateToken(TokenKind.InterpStringStart);
    }

    /// <summary>
    /// Scan a segment: text between interp boundaries. Emits InterpSegment and
    /// (depending on what terminated it) queues InterpHoleStart or InterpStringEnd.
    /// Handles normal string escapes plus segment-only `{{` / `}}` doubling.
    /// </summary>
    private Token LexSegment(ReadOnlySpan<char> text, InterpFrame frame)
    {
        _start = _position;
        var sb = new StringBuilder();

        while (_position < text.Length)
        {
            var c = text[_position];

            if (c == '"')
            {
                // End of the interpolated string. Emit segment first, queue end.
                var segSpan = CreateSpan();
                var segText = sb.ToString();
                _start = _position;
                _position++; // consume `"`
                var endToken = new Token(TokenKind.InterpStringEnd, CreateSpan(), "\"");
                // Pop this interp frame.
                _interpStack.RemoveAt(_interpStack.Count - 1);
                _pendingToken = endToken;
                return new Token(TokenKind.InterpSegment, segSpan, segText);
            }

            if (c == '{')
            {
                if (_position + 1 < text.Length && text[_position + 1] == '{')
                {
                    sb.Append('{');
                    _position += 2;
                    continue;
                }
                // Start of a hole. Flush segment, queue hole-start, switch to hole mode.
                var segSpan = CreateSpan();
                var segText = sb.ToString();
                _start = _position;
                _position++; // consume `{`
                var holeStartToken = new Token(TokenKind.InterpHoleStart, CreateSpan(), "{");
                frame.InSegment = false;
                frame.BraceDepth = 0;
                frame.ParenDepth = 0;
                frame.BracketDepth = 0;
                _pendingToken = holeStartToken;
                return new Token(TokenKind.InterpSegment, segSpan, segText);
            }

            if (c == '}')
            {
                if (_position + 1 < text.Length && text[_position + 1] == '}')
                {
                    sb.Append('}');
                    _position += 2;
                    continue;
                }
                // Bare `}` in a segment is an error — treated as a BadToken so
                // the parser/diagnostics can report it.
                _start = _position;
                _position++;
                return CreateTokenWithValue(TokenKind.BadToken, "}");
            }

            if (c == '\\' && _position + 1 < text.Length)
            {
                _position++;
                var escChar = text[_position];
                if (escChar == 'u')
                {
                    _position++;
                    var cp = ReadUnicodeEscape(text);
                    if (cp < 0)
                        return CreateTokenWithValue(TokenKind.BadToken, "");
                    sb.Append(char.ConvertFromUtf32(cp));
                    continue;
                }
                var escaped = escChar switch
                {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '0' => '\0',
                    _ => escChar
                };
                sb.Append(escaped);
                _position++;
                continue;
            }

            if (c == '\n') _line++;
            sb.Append(c);
            _position++;
        }

        // EOF with unterminated segment.
        _interpStack.Clear();
        return CreateTokenWithValue(TokenKind.BadToken, "");
    }

    /// <summary>
    /// Scan a format spec: raw characters between `:` and the matching `}` of
    /// the current hole. No escape handling, no parsing. Emits InterpFormatSpec
    /// and queues InterpHoleEnd for the closing `}`.
    /// </summary>
    private Token LexFormatSpec(ReadOnlySpan<char> text, InterpFrame frame)
    {
        _start = _position;
        while (_position < text.Length && text[_position] != '}' && text[_position] != '"')
        {
            if (text[_position] == '\n') _line++;
            _position++;
        }

        if (_position >= text.Length || text[_position] == '"')
        {
            // Unterminated hole — bail out.
            _interpStack.Clear();
            return CreateTokenWithValue(TokenKind.BadToken, "");
        }

        var specText = text[_start.._position].ToString();
        var specSpan = CreateSpan();

        _start = _position;
        _position++; // consume `}`
        var holeEndToken = new Token(TokenKind.InterpHoleEnd, CreateSpan(), "}");
        frame.InFormatSpec = false;
        frame.InSegment = true;
        _pendingToken = holeEndToken;

        return new Token(TokenKind.InterpFormatSpec, specSpan, specText);
    }

    /// <summary>
    /// Track bracket depth and intercept the `}` that closes the current hole
    /// and the `:` that starts a format spec. Everything else falls through as
    /// the lexer emitted it.
    /// </summary>
    private Token AdjustForHoleMode(Token token, InterpFrame frame)
    {
        switch (token.Kind)
        {
            case TokenKind.OpenBrace:
                frame.BraceDepth++;
                return token;
            case TokenKind.OpenParenthesis:
                frame.ParenDepth++;
                return token;
            case TokenKind.OpenBracket:
                frame.BracketDepth++;
                return token;
            case TokenKind.CloseBrace:
                if (frame.BraceDepth == 0)
                {
                    // This `}` closes the current hole.
                    frame.InSegment = true;
                    return new Token(TokenKind.InterpHoleEnd, token.Span, "}");
                }
                frame.BraceDepth--;
                return token;
            case TokenKind.CloseParenthesis:
                if (frame.ParenDepth > 0) frame.ParenDepth--;
                return token;
            case TokenKind.CloseBracket:
                if (frame.BracketDepth > 0) frame.BracketDepth--;
                return token;
            case TokenKind.Colon:
                if (frame.BraceDepth == 0 && frame.ParenDepth == 0 && frame.BracketDepth == 0)
                {
                    // Format-spec separator. Switch mode; the raw spec and
                    // closing `}` are lexed by LexFormatSpec on the next call.
                    frame.InFormatSpec = true;
                    return new Token(TokenKind.InterpFormatSep, token.Span, ":");
                }
                return token;
            default:
                return token;
        }
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
