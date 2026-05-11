// Lexer — turns a source buffer into a stream of Tokens, with leading and
// trailing trivia attached to each token. The token stream is lossless:
// concatenating leading + text + trailing across every token reproduces the
// source file byte-for-byte.

import std.list
import flang_parser.token
import flang_parser.trivia

// Expose flang_parser's own version through the project_info() intrinsic.
// Called from inside this module, project_info() returns flang_parser's
// metadata; consumers that want their own version call project_info()
// directly.
pub fn parser_version() String {
    return project_info().version
}

pub type Lexer = struct {
    source: String
    position: usize
}

pub fn lexer(source: String) Lexer {
    return .{ source = source, position = 0 }
}

// Drive the lexer to completion and collect every token, including the
// terminating Eof.
pub fn tokenize(self: &Lexer) List(Token) {
    let tokens: List(Token) = list(8)
    let eof_text: String = ""
    let leading: List(Trivia) = list(0)
    let trailing: List(Trivia) = list(0)
    tokens.push(Token {
        kind = TokenKind.Eof,
        text = eof_text,
        offset = self.position,
        leading = leading,
        trailing = trailing,
    })
    return tokens
}
