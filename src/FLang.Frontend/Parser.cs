using System.Collections.Generic;
using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

public class Parser
{
    private readonly Lexer _lexer;
    private Token _currentToken;

    public Parser(Lexer lexer)
    {
        _lexer = lexer;
        _currentToken = _lexer.NextToken();
    }

    public ModuleNode ParseModule()
    {
        var startSpan = _currentToken.Span;
        var imports = new List<ImportDeclarationNode>();
        var structs = new List<StructDeclarationNode>();
        var functions = new List<FunctionDeclarationNode>();

        // Parse imports
        while (_currentToken.Kind == TokenKind.Import)
        {
            imports.Add(ParseImport());
        }

        // Parse structs and functions
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            if (_currentToken.Kind == TokenKind.Hash)
            {
                // Foreign function
                Eat(TokenKind.Hash);
                Eat(TokenKind.Foreign);
                functions.Add(ParseFunction(true));
            }
            else if (_currentToken.Kind == TokenKind.Pub)
            {
                // Could be struct or function - peek ahead
                var nextToken = PeekNextToken();
                if (nextToken.Kind == TokenKind.Struct)
                {
                    Eat(TokenKind.Pub);
                    structs.Add(ParseStruct());
                }
                else if (nextToken.Kind == TokenKind.Fn)
                {
                    functions.Add(ParseFunction(false));
                }
                else
                {
                    throw new Exception($"Expected 'struct' or 'fn' after 'pub', got {nextToken.Kind}");
                }
            }
            else if (_currentToken.Kind == TokenKind.Struct)
            {
                // Struct without pub (allowed for now)
                structs.Add(ParseStruct());
            }
            else
            {
                // Error: unexpected token
                throw new Exception($"Unexpected token: {_currentToken.Kind}");
            }
        }

        var endSpan = _currentToken.Span;
        var span = new SourceSpan(startSpan.FileId, startSpan.Index, endSpan.Index + endSpan.Length - startSpan.Index);
        return new ModuleNode(span, imports, structs, functions);
    }

    private ImportDeclarationNode ParseImport()
    {
        var importKeyword = Eat(TokenKind.Import);
        var path = new List<string>();

        // Parse the first identifier
        var firstIdentifier = Eat(TokenKind.Identifier);
        path.Add(firstIdentifier.Text);

        // Parse additional path components (e.g., std.io.File)
        while (_currentToken.Kind == TokenKind.Dot)
        {
            Eat(TokenKind.Dot);
            var identifier = Eat(TokenKind.Identifier);
            path.Add(identifier.Text);
        }

        var span = new SourceSpan(importKeyword.Span.FileId, importKeyword.Span.Index, _currentToken.Span.Index - importKeyword.Span.Index);
        return new ImportDeclarationNode(span, path);
    }

    private StructDeclarationNode ParseStruct()
    {
        var structKeyword = Eat(TokenKind.Struct);
        var nameToken = Eat(TokenKind.Identifier);

        // Parse optional generic type parameters: [T, U, V]
        var typeParameters = new List<string>();
        if (_currentToken.Kind == TokenKind.OpenBracket)
        {
            Eat(TokenKind.OpenBracket);

            while (_currentToken.Kind != TokenKind.CloseBracket && _currentToken.Kind != TokenKind.EndOfFile)
            {
                var typeParam = Eat(TokenKind.Identifier);
                typeParameters.Add(typeParam.Text);

                if (_currentToken.Kind == TokenKind.Comma)
                {
                    Eat(TokenKind.Comma);
                }
                else if (_currentToken.Kind != TokenKind.CloseBracket)
                {
                    break;
                }
            }

            Eat(TokenKind.CloseBracket);
        }

        // Parse struct body: { field: Type, field2: Type2 }
        Eat(TokenKind.OpenBrace);

        var fields = new List<StructFieldNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var fieldType = ParseType();

            var fieldSpan = new SourceSpan(fieldNameToken.Span.FileId, fieldNameToken.Span.Index, fieldType.Span.Index + fieldType.Span.Length - fieldNameToken.Span.Index);
            fields.Add(new StructFieldNode(fieldSpan, fieldNameToken.Text, fieldType));

            // Fields can be separated by commas or newlines (optional)
            if (_currentToken.Kind == TokenKind.Comma)
            {
                Eat(TokenKind.Comma);
            }
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = new SourceSpan(structKeyword.Span.FileId, structKeyword.Span.Index, closeBrace.Span.Index + closeBrace.Span.Length - structKeyword.Span.Index);
        return new StructDeclarationNode(span, nameToken.Text, typeParameters, fields);
    }

    public FunctionDeclarationNode ParseFunction(bool isForeign = false)
    {
        var pubKeyword = Eat(TokenKind.Pub);
        var fnKeyword = Eat(TokenKind.Fn);
        var identifier = Eat(TokenKind.Identifier);
        Eat(TokenKind.OpenParenthesis);

        // Parse parameter list
        var parameters = new List<FunctionParameterNode>();
        while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var paramNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var paramType = ParseType();

            var paramSpan = new SourceSpan(paramNameToken.Span.FileId, paramNameToken.Span.Index, paramType.Span.Index + paramType.Span.Length - paramNameToken.Span.Index);
            parameters.Add(new FunctionParameterNode(paramSpan, paramNameToken.Text, paramType));

            // If there's a comma, consume it and continue parsing parameters
            if (_currentToken.Kind == TokenKind.Comma)
            {
                Eat(TokenKind.Comma);
            }
            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
            {
                // Error: expected comma or close parenthesis
                break;
            }
        }

        Eat(TokenKind.CloseParenthesis);

        // Parse return type (optional for now, but expected in new syntax)
        TypeNode? returnType = null;
        if (_currentToken.Kind == TokenKind.Identifier || _currentToken.Kind == TokenKind.Ampersand)
        {
            returnType = ParseType();
        }

        var statements = new List<StatementNode>();

        if (isForeign)
        {
            // Foreign functions have no body
            var span = new SourceSpan(pubKeyword.Span.FileId, pubKeyword.Span.Index, _currentToken.Span.Index - pubKeyword.Span.Index);
            return new FunctionDeclarationNode(span, identifier.Text, parameters, returnType, statements, isForeign: true);
        }
        else
        {
            Eat(TokenKind.OpenBrace);

            while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
            {
                statements.Add(ParseStatement());
            }

            Eat(TokenKind.CloseBrace);

            var span = new SourceSpan(pubKeyword.Span.FileId, pubKeyword.Span.Index, _currentToken.Span.Index + _currentToken.Span.Length - pubKeyword.Span.Index);
            return new FunctionDeclarationNode(span, identifier.Text, parameters, returnType, statements);
        }
    }

    private StatementNode ParseStatement()
    {
        switch (_currentToken.Kind)
        {
            case TokenKind.Let:
                return ParseVariableDeclaration();

            case TokenKind.Return:
            {
                var returnKeyword = Eat(TokenKind.Return);
                var expression = ParseExpression();
                var span = new SourceSpan(returnKeyword.Span.FileId, returnKeyword.Span.Index, _currentToken.Span.Index - returnKeyword.Span.Index);
                return new ReturnStatementNode(span, expression);
            }

            case TokenKind.Break:
            {
                var breakKeyword = Eat(TokenKind.Break);
                return new BreakStatementNode(breakKeyword.Span);
            }

            case TokenKind.Continue:
            {
                var continueKeyword = Eat(TokenKind.Continue);
                return new ContinueStatementNode(continueKeyword.Span);
            }

            case TokenKind.For:
                return ParseForLoop();

            default:
                throw new Exception($"Unexpected token in statement: {_currentToken.Kind}");
        }
    }

    private VariableDeclarationNode ParseVariableDeclaration()
    {
        var letKeyword = Eat(TokenKind.Let);
        var identifier = Eat(TokenKind.Identifier);

        TypeNode? type = null;
        if (_currentToken.Kind == TokenKind.Colon)
        {
            Eat(TokenKind.Colon);
            type = ParseType();
        }

        ExpressionNode? initializer = null;
        if (_currentToken.Kind == TokenKind.Equals)
        {
            Eat(TokenKind.Equals);
            initializer = ParseExpression();
        }

        var span = new SourceSpan(letKeyword.Span.FileId, letKeyword.Span.Index, _currentToken.Span.Index - letKeyword.Span.Index);
        return new VariableDeclarationNode(span, identifier.Text, type, initializer);
    }

    private ExpressionNode ParseExpression()
    {
        return ParseBinaryExpression(0);
    }

    private ExpressionNode ParseBinaryExpression(int parentPrecedence)
    {
        var left = ParsePrimaryExpression();

        // Handle postfix operators (like .*)
        left = ParsePostfixOperators(left);

        while (true)
        {
            // Check for assignment (special case: identifier = expression)
            if (_currentToken.Kind == TokenKind.Equals && left is IdentifierExpressionNode identifier)
            {
                _currentToken = _lexer.NextToken();
                var value = ParseExpression(); // Right-associative, so parse full expression
                var assignSpan = new SourceSpan(left.Span.FileId, left.Span.Index, value.Span.Index + value.Span.Length - left.Span.Index);
                return new AssignmentExpressionNode(assignSpan, identifier.Name, value);
            }

            var precedence = GetBinaryOperatorPrecedence(_currentToken.Kind);
            if (precedence == 0 || precedence <= parentPrecedence)
                break;

            var operatorToken = _currentToken;

            // Special handling for range operator
            if (operatorToken.Kind == TokenKind.DotDot)
            {
                _currentToken = _lexer.NextToken();
                var rangeEnd = ParseBinaryExpression(precedence);
                var rangeSpan = new SourceSpan(left.Span.FileId, left.Span.Index, rangeEnd.Span.Index + rangeEnd.Span.Length - left.Span.Index);
                left = new RangeExpressionNode(rangeSpan, left, rangeEnd);
                continue;
            }

            var operatorKind = GetBinaryOperatorKind(operatorToken.Kind);
            _currentToken = _lexer.NextToken();

            var right = ParseBinaryExpression(precedence);

            var span = new SourceSpan(left.Span.FileId, left.Span.Index, right.Span.Index + right.Span.Length - left.Span.Index);
            left = new BinaryExpressionNode(span, left, operatorKind, right);
        }

        return left;
    }

    private ExpressionNode ParsePostfixOperators(ExpressionNode expr)
    {
        while (true)
        {
            // Handle dot operator: either ptr.* (dereference) or obj.field (field access)
            if (_currentToken.Kind == TokenKind.Dot)
            {
                var dotToken = Eat(TokenKind.Dot);
                if (_currentToken.Kind == TokenKind.Star)
                {
                    // Dereference: ptr.*
                    var starToken = Eat(TokenKind.Star);
                    var span = new SourceSpan(expr.Span.FileId, expr.Span.Index, starToken.Span.Index + starToken.Span.Length - expr.Span.Index);
                    expr = new DereferenceExpressionNode(span, expr);
                    continue;
                }
                else if (_currentToken.Kind == TokenKind.Identifier)
                {
                    // Field access: obj.field
                    var fieldToken = Eat(TokenKind.Identifier);
                    var span = new SourceSpan(expr.Span.FileId, expr.Span.Index, fieldToken.Span.Index + fieldToken.Span.Length - expr.Span.Index);
                    expr = new FieldAccessExpressionNode(span, expr, fieldToken.Text);
                    continue;
                }
                else
                {
                    throw new Exception($"Expected '*' or identifier after '.', got {_currentToken.Kind}");
                }
            }
            // Handle index operator: arr[i]
            else if (_currentToken.Kind == TokenKind.OpenBracket)
            {
                var openBracket = Eat(TokenKind.OpenBracket);
                var index = ParseExpression();
                var closeBracket = Eat(TokenKind.CloseBracket);
                var span = new SourceSpan(expr.Span.FileId, expr.Span.Index, closeBracket.Span.Index + closeBracket.Span.Length - expr.Span.Index);
                expr = new IndexExpressionNode(span, expr, index);
                continue;
            }

            break;
        }

        return expr;
    }

    private ExpressionNode ParsePrimaryExpression()
    {
        switch (_currentToken.Kind)
        {
            case TokenKind.Ampersand:
            {
                // Address-of operator: &variable
                var ampToken = Eat(TokenKind.Ampersand);
                var target = ParsePrimaryExpression(); // Parse the target expression
                var span = new SourceSpan(ampToken.Span.FileId, ampToken.Span.Index, target.Span.Index + target.Span.Length - ampToken.Span.Index);
                return new AddressOfExpressionNode(span, target);
            }

            case TokenKind.Integer:
            {
                var integerToken = Eat(TokenKind.Integer);
                var value = long.Parse(integerToken.Text);
                return new IntegerLiteralNode(integerToken.Span, value);
            }

            case TokenKind.True:
            {
                var trueToken = Eat(TokenKind.True);
                return new BooleanLiteralNode(trueToken.Span, true);
            }

            case TokenKind.False:
            {
                var falseToken = Eat(TokenKind.False);
                return new BooleanLiteralNode(falseToken.Span, false);
            }

            case TokenKind.Identifier:
            {
                var identifierToken = Eat(TokenKind.Identifier);

                // Check if this is a struct construction: TypeName { field: value }
                if (_currentToken.Kind == TokenKind.OpenBrace)
                {
                    // Parse as struct construction
                    var typeName = new NamedTypeNode(identifierToken.Span, identifierToken.Text);
                    return ParseStructConstruction(typeName);
                }

                // Check if this is a function call
                if (_currentToken.Kind == TokenKind.OpenParenthesis)
                {
                    Eat(TokenKind.OpenParenthesis);
                    var arguments = new List<ExpressionNode>();

                    // Parse arguments
                    while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
                    {
                        arguments.Add(ParseExpression());

                        // If there's a comma, consume it and continue parsing arguments
                        if (_currentToken.Kind == TokenKind.Comma)
                        {
                            Eat(TokenKind.Comma);
                        }
                        else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                        {
                            // Error: expected comma or close parenthesis
                            break;
                        }
                    }

                    var closeParenToken = Eat(TokenKind.CloseParenthesis);
                    var callSpan = new SourceSpan(identifierToken.Span.FileId, identifierToken.Span.Index, closeParenToken.Span.Index + closeParenToken.Span.Length - identifierToken.Span.Index);
                    return new CallExpressionNode(callSpan, identifierToken.Text, arguments);
                }

                return new IdentifierExpressionNode(identifierToken.Span, identifierToken.Text);
            }

            case TokenKind.OpenParenthesis:
            {
                Eat(TokenKind.OpenParenthesis);
                var expression = ParseExpression();
                Eat(TokenKind.CloseParenthesis);
                return expression;
            }

            case TokenKind.If:
                return ParseIfExpression();

            case TokenKind.OpenBrace:
                return ParseBlockExpression();

            case TokenKind.OpenBracket:
                return ParseArrayLiteral();

            default:
                throw new Exception($"Unexpected token in expression: {_currentToken.Kind}");
        }
    }

    private int GetBinaryOperatorPrecedence(TokenKind kind)
    {
        return kind switch
        {
            TokenKind.Star or TokenKind.Slash or TokenKind.Percent => 5,
            TokenKind.Plus or TokenKind.Minus => 4,
            TokenKind.DotDot => 3,
            TokenKind.LessThan or TokenKind.GreaterThan or TokenKind.LessThanOrEqual or TokenKind.GreaterThanOrEqual => 2,
            TokenKind.EqualsEquals or TokenKind.NotEquals => 1,
            _ => 0
        };
    }

    private BinaryOperatorKind GetBinaryOperatorKind(TokenKind kind)
    {
        return kind switch
        {
            TokenKind.Plus => BinaryOperatorKind.Add,
            TokenKind.Minus => BinaryOperatorKind.Subtract,
            TokenKind.Star => BinaryOperatorKind.Multiply,
            TokenKind.Slash => BinaryOperatorKind.Divide,
            TokenKind.Percent => BinaryOperatorKind.Modulo,
            TokenKind.EqualsEquals => BinaryOperatorKind.Equal,
            TokenKind.NotEquals => BinaryOperatorKind.NotEqual,
            TokenKind.LessThan => BinaryOperatorKind.LessThan,
            TokenKind.GreaterThan => BinaryOperatorKind.GreaterThan,
            TokenKind.LessThanOrEqual => BinaryOperatorKind.LessThanOrEqual,
            TokenKind.GreaterThanOrEqual => BinaryOperatorKind.GreaterThanOrEqual,
            _ => throw new Exception($"Unexpected operator token: {kind}")
        };
    }

    private IfExpressionNode ParseIfExpression()
    {
        var ifKeyword = Eat(TokenKind.If);
        Eat(TokenKind.OpenParenthesis);
        var condition = ParseExpression();
        Eat(TokenKind.CloseParenthesis);

        var thenBranch = ParseExpression();

        ExpressionNode? elseBranch = null;
        if (_currentToken.Kind == TokenKind.Else)
        {
            Eat(TokenKind.Else);
            elseBranch = ParseExpression();
        }

        var endPos = elseBranch?.Span ?? thenBranch.Span;
        var span = new SourceSpan(ifKeyword.Span.FileId, ifKeyword.Span.Index, endPos.Index + endPos.Length - ifKeyword.Span.Index);
        return new IfExpressionNode(span, condition, thenBranch, elseBranch);
    }

    private StructConstructionExpressionNode ParseStructConstruction(TypeNode typeName)
    {
        var openBrace = Eat(TokenKind.OpenBrace);
        var fields = new List<(string, ExpressionNode)>();

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var fieldValue = ParseExpression();

            fields.Add((fieldNameToken.Text, fieldValue));

            // Fields can be separated by commas
            if (_currentToken.Kind == TokenKind.Comma)
            {
                Eat(TokenKind.Comma);
            }
            else if (_currentToken.Kind != TokenKind.CloseBrace)
            {
                // Allow newlines as separators too
                break;
            }
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = new SourceSpan(typeName.Span.FileId, typeName.Span.Index, closeBrace.Span.Index + closeBrace.Span.Length - typeName.Span.Index);
        return new StructConstructionExpressionNode(span, typeName, fields);
    }

    private BlockExpressionNode ParseBlockExpression()
    {
        var openBrace = Eat(TokenKind.OpenBrace);
        var statements = new List<StatementNode>();
        ExpressionNode? trailingExpression = null;

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            // Check if this might be a trailing expression (no statement keywords)
            if (_currentToken.Kind != TokenKind.Let &&
                _currentToken.Kind != TokenKind.Return &&
                _currentToken.Kind != TokenKind.For &&
                _currentToken.Kind != TokenKind.Break &&
                _currentToken.Kind != TokenKind.Continue)
            {
                // Try to parse as expression
                var expr = ParseExpression();

                // If it's the last thing before }, it's a trailing expression
                if (_currentToken.Kind == TokenKind.CloseBrace)
                {
                    trailingExpression = expr;
                    break;
                }

                // Assignment and if expressions are allowed as statements
                if (expr is AssignmentExpressionNode or IfExpressionNode)
                {
                    // Wrap in ExpressionStatementNode
                    statements.Add(new ExpressionStatementNode(expr.Span, expr));
                    continue;
                }

                // Other expression statements not supported
                throw new Exception("Expression statements not yet supported (except assignments and if)");
            }
            else
            {
                statements.Add(ParseStatement());
            }
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = new SourceSpan(openBrace.Span.FileId, openBrace.Span.Index, closeBrace.Span.Index + closeBrace.Span.Length - openBrace.Span.Index);
        return new BlockExpressionNode(span, statements, trailingExpression);
    }

    private ForLoopNode ParseForLoop()
    {
        var forKeyword = Eat(TokenKind.For);
        Eat(TokenKind.OpenParenthesis);
        var iterator = Eat(TokenKind.Identifier);
        Eat(TokenKind.In);
        var iterable = ParseExpression();
        Eat(TokenKind.CloseParenthesis);

        var body = ParseExpression();

        var span = new SourceSpan(forKeyword.Span.FileId, forKeyword.Span.Index, body.Span.Index + body.Span.Length - forKeyword.Span.Index);
        return new ForLoopNode(span, iterator.Text, iterable, body);
    }

    /// <summary>
    /// Parses a type expression with support for references, generics, and nullable types.
    /// Grammar:
    ///   type := prefix_type postfix*
    ///   prefix_type := '&' prefix_type | primary_type
    ///   primary_type := identifier generic_args?
    ///   generic_args := '[' type (',' type)* ']'
    ///   postfix := '?'
    /// Examples:
    ///   i32, &i32, i32?, &i32?, List[i32], &List[i32]?, Dict[String, i32]
    /// </summary>
    private TypeNode ParseType()
    {
        var startPos = _currentToken.Span.Index;

        // Parse prefix operators (reference: &)
        TypeNode type;
        if (_currentToken.Kind == TokenKind.Ampersand)
        {
            var ampToken = Eat(TokenKind.Ampersand);
            var innerType = ParseType(); // Recursively parse for nested references
            var span = new SourceSpan(ampToken.Span.FileId, startPos, _currentToken.Span.Index - startPos);
            type = new ReferenceTypeNode(span, innerType);
        }
        else
        {
            // Parse primary type (named type, array, or generic)
            type = ParsePrimaryType();
        }

        // Parse postfix operators (nullable: ?, slice: [])
        while (true)
        {
            if (_currentToken.Kind == TokenKind.Question)
            {
                var questionToken = Eat(TokenKind.Question);
                var span = new SourceSpan(type.Span.FileId, startPos, questionToken.Span.Index + questionToken.Span.Length - startPos);
                type = new NullableTypeNode(span, type);
            }
            else if (_currentToken.Kind == TokenKind.OpenBracket && PeekNextToken().Kind == TokenKind.CloseBracket)
            {
                // T[] - slice type (only if next token is immediately ']')
                var openBracket = Eat(TokenKind.OpenBracket);
                var closeBracket = Eat(TokenKind.CloseBracket);
                var span = new SourceSpan(type.Span.FileId, startPos, closeBracket.Span.Index + closeBracket.Span.Length - startPos);
                type = new SliceTypeNode(span, type);
            }
            else
            {
                break;
            }
        }

        return type;
    }

    /// <summary>
    /// Parses a primary type (identifier with optional generic arguments, or array type).
    /// Examples: i32, List[T], Dict[K, V], [i32; 5]
    /// </summary>
    private TypeNode ParsePrimaryType()
    {
        // Check for array type: [T; N]
        if (_currentToken.Kind == TokenKind.OpenBracket)
        {
            var openBracket = Eat(TokenKind.OpenBracket);
            var elementType = ParseType();
            Eat(TokenKind.Semicolon);
            var lengthToken = Eat(TokenKind.Integer);
            var closeBracket = Eat(TokenKind.CloseBracket);

            if (!int.TryParse(lengthToken.Text, out var length))
            {
                throw new Exception($"Invalid array length: {lengthToken.Text}");
            }

            var span = new SourceSpan(openBracket.Span.FileId, openBracket.Span.Index, closeBracket.Span.Index + closeBracket.Span.Length - openBracket.Span.Index);
            return new ArrayTypeNode(span, elementType, length);
        }

        var nameToken = Eat(TokenKind.Identifier);

        // Check for generic arguments
        if (_currentToken.Kind == TokenKind.OpenBracket)
        {
            Eat(TokenKind.OpenBracket);
            var typeArgs = new List<TypeNode>();

            while (_currentToken.Kind != TokenKind.CloseBracket && _currentToken.Kind != TokenKind.EndOfFile)
            {
                typeArgs.Add(ParseType());

                if (_currentToken.Kind == TokenKind.Comma)
                {
                    Eat(TokenKind.Comma);
                }
                else if (_currentToken.Kind != TokenKind.CloseBracket)
                {
                    break;
                }
            }

            var closeBracket = Eat(TokenKind.CloseBracket);
            var span = new SourceSpan(nameToken.Span.FileId, nameToken.Span.Index, closeBracket.Span.Index + closeBracket.Span.Length - nameToken.Span.Index);
            return new GenericTypeNode(span, nameToken.Text, typeArgs);
        }

        return new NamedTypeNode(nameToken.Span, nameToken.Text);
    }

    private Token PeekNextToken()
    {
        // Save current lexer state and get next token
        return _lexer.PeekNextToken();
    }

    private ExpressionNode ParseArrayLiteral()
    {
        var openBracket = Eat(TokenKind.OpenBracket);

        // Empty array: []
        if (_currentToken.Kind == TokenKind.CloseBracket)
        {
            var closeBracket = Eat(TokenKind.CloseBracket);
            var span = new SourceSpan(openBracket.Span.FileId, openBracket.Span.Index, closeBracket.Span.Index + closeBracket.Span.Length - openBracket.Span.Index);
            return new ArrayLiteralExpressionNode(span, new List<ExpressionNode>());
        }

        // Parse first element
        var firstElement = ParseExpression();

        // Check if this is repeat syntax: [value; count]
        if (_currentToken.Kind == TokenKind.Semicolon)
        {
            Eat(TokenKind.Semicolon);
            var countToken = Eat(TokenKind.Integer);
            var closeBracket = Eat(TokenKind.CloseBracket);

            if (!int.TryParse(countToken.Text, out var count))
            {
                throw new Exception($"Invalid array repeat count: {countToken.Text}");
            }

            var span = new SourceSpan(openBracket.Span.FileId, openBracket.Span.Index, closeBracket.Span.Index + closeBracket.Span.Length - openBracket.Span.Index);
            return new ArrayLiteralExpressionNode(span, firstElement, count);
        }

        // Regular array literal: [elem1, elem2, ...]
        var elements = new List<ExpressionNode> { firstElement };

        while (_currentToken.Kind == TokenKind.Comma)
        {
            Eat(TokenKind.Comma);

            // Allow trailing comma
            if (_currentToken.Kind == TokenKind.CloseBracket)
                break;

            elements.Add(ParseExpression());
        }

        var closeBracketToken = Eat(TokenKind.CloseBracket);
        var finalSpan = new SourceSpan(openBracket.Span.FileId, openBracket.Span.Index, closeBracketToken.Span.Index + closeBracketToken.Span.Length - openBracket.Span.Index);
        return new ArrayLiteralExpressionNode(finalSpan, elements);
    }

    private Token Eat(TokenKind kind)
    {
        var token = _currentToken;
        if (token.Kind != kind)
            throw new Exception($"Expected {kind}, but got {token.Kind}");
        _currentToken = _lexer.NextToken();
        return token;
    }
}
