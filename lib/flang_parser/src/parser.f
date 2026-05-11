// Parser — turns a Token stream into a CstNode tree.
//
// Recursive descent. Error recovery produces NodeKind.Error subtrees that
// preserve their child tokens, so the formatter can still round-trip
// broken source.

import std.list
import flang_parser.token
import flang_parser.lexer
import flang_parser.cst

pub type Parser = struct {
    tokens: List(Token)
    position: usize
}

pub fn parser(tokens: List(Token)) Parser {
    return .{ tokens = tokens, position = 0 }
}

// Parse a complete module.
pub fn parse_module(self: &Parser) CstNode {
    let children: List(CstChild) = list(0)
    return .{
        kind = NodeKind.Module,
        start = 0,
        end = 0,
        children = children,
    }
}
