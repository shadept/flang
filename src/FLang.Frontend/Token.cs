using FLang.Core;

namespace FLang.Frontend;

public record Token(TokenKind Kind, SourceSpan Span, string Text);