using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

/// <summary>
/// Recursive descent parser for FLang source code that produces an Abstract Syntax Tree (AST).
/// </summary>
public class Parser
{
    private readonly Lexer _lexer;
    private Token _currentToken;
    private readonly List<Diagnostic> _diagnostics = [];

    /// <summary>
    /// Initializes a new instance of the <see cref="Parser"/> class.
    /// </summary>
    /// <param name="lexer">The lexer that provides tokens for parsing.</param>
    public Parser(Lexer lexer)
    {
        _lexer = lexer;
        _currentToken = _lexer.NextToken();
    }

    /// <summary>
    /// Gets the list of diagnostics (errors and warnings) encountered during parsing.
    /// </summary>
    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    /// <summary>
    /// Parses a complete module, including imports, struct declarations, enum declarations, and function declarations.
    /// </summary>
    /// <returns>A <see cref="ModuleNode"/> representing the parsed module.</returns>
    public ModuleNode ParseModule()
    {
        var startSpan = _currentToken.Span;
        var imports = new List<ImportDeclarationNode>();
        var structs = new List<StructDeclarationNode>();
        var enums = new List<EnumDeclarationNode>();
        var functions = new List<FunctionDeclarationNode>();
        var tests = new List<TestDeclarationNode>();

        // Parse imports
        while (_currentToken.Kind == TokenKind.Import) imports.Add(ParseImport());

        // Parse structs, functions, and tests
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            try
            {
                if (_currentToken.Kind == TokenKind.Hash)
                {
                    // Directive(s), currently only #foreign
                    Eat(TokenKind.Hash);
                    var directive = Eat(TokenKind.Foreign);
                    functions.Add(ParseFunction(FunctionModifiers.Foreign));
                }
                else if (_currentToken.Kind == TokenKind.Pub)
                {
                    // Could be struct, enum, or function - peek ahead
                    var nextToken = PeekNextToken();
                    if (nextToken.Kind == TokenKind.Struct)
                    {
                        Eat(TokenKind.Pub);
                        structs.Add(ParseStruct());
                    }
                    else if (nextToken.Kind == TokenKind.Enum)
                    {
                        Eat(TokenKind.Pub);
                        enums.Add(ParseEnumDeclaration());
                    }
                    else if (nextToken.Kind == TokenKind.Fn)
                    {
                        functions.Add(ParseFunction());
                    }
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"expected `struct`, `enum`, or `fn` after `pub`",
                            _currentToken.Span,
                            $"found '{nextToken.Text}'",
                            "E1002"));
                        // Consume `pub` to prevent infinite loop and continue
                        _currentToken = _lexer.NextToken();
                    }
                }
                else if (_currentToken.Kind == TokenKind.Struct)
                {
                    // Struct without pub (allowed for now)
                    structs.Add(ParseStruct());
                }
                else if (_currentToken.Kind == TokenKind.Enum)
                {
                    // Enum without pub (allowed for now)
                    enums.Add(ParseEnumDeclaration());
                }
                else if (_currentToken.Kind == TokenKind.Fn)
                {
                    // Non-public function
                    functions.Add(ParseFunction());
                }
                else if (_currentToken.Kind == TokenKind.Test)
                {
                    // Test block
                    tests.Add(ParseTest());
                }
                else
                {
                    // Unexpected token: report and attempt to recover by skipping it
                    _diagnostics.Add(Diagnostic.Error(
                        $"unexpected token '{_currentToken.Text}'",
                        _currentToken.Span,
                        "expected `struct`, `enum`, `pub fn`, `fn`, `test`, or `#foreign fn`",
                        "E1001"));
                    _currentToken = _lexer.NextToken();
                }
            }
            catch (ParserException ex)
            {
                _diagnostics.Add(ex.Diagnostic);
                SynchronizeTopLevel();
            }
        }

        var endSpan = _currentToken.Span;
        var span = SourceSpan.Combine(startSpan, endSpan);
        return new ModuleNode(span, imports, structs, enums, functions, tests);
    }

    /// <summary>
    /// Parses an import declaration (e.g., import std.io.File).
    /// </summary>
    /// <returns>An <see cref="ImportDeclarationNode"/> representing the import statement.</returns>
    private ImportDeclarationNode ParseImport()
    {
        var importKeyword = Eat(TokenKind.Import);
        var path = new List<string>();

        // Parse the first identifier (or keyword used as module name)
        var firstIdentifier = EatIdentifierOrKeyword();
        path.Add(firstIdentifier.Text);

        // Parse additional path components (e.g., std.io.File)
        while (_currentToken.Kind == TokenKind.Dot)
        {
            Eat(TokenKind.Dot);
            var identifier = EatIdentifierOrKeyword();
            path.Add(identifier.Text);
        }

        var span = SourceSpan.Combine(importKeyword.Span, _currentToken.Span);
        return new ImportDeclarationNode(span, path);
    }

    /// <summary>
    /// Eats an identifier or a keyword that can be used as an identifier in certain contexts
    /// (e.g., module names in import paths like "std.test").
    /// </summary>
    private Token EatIdentifierOrKeyword()
    {
        // Keywords that can be used as module/path names
        if (_currentToken.Kind == TokenKind.Identifier ||
            _currentToken.Kind == TokenKind.Test)
        {
            var token = _currentToken;
            _currentToken = _lexer.NextToken();
            return token;
        }

        throw new ParserException(Diagnostic.Error(
            $"expected identifier",
            _currentToken.Span,
            $"found '{_currentToken.Text}'",
            "E1002"));
    }

    /// <summary>
    /// Parses a struct declaration with optional generic type parameters.
    /// </summary>
    /// <returns>A <see cref="StructDeclarationNode"/> representing the struct definition.</returns>
    private StructDeclarationNode ParseStruct()
    {
        var structKeyword = Eat(TokenKind.Struct);
        var nameToken = Eat(TokenKind.Identifier);

        // Parse optional generic type parameters: (T, U, V)
        var typeParameters = new List<string>();
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            Eat(TokenKind.OpenParenthesis);

            while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
            {
                var typeParam = Eat(TokenKind.Identifier);
                typeParameters.Add(typeParam.Text);

                if (_currentToken.Kind == TokenKind.Comma)
                    Eat(TokenKind.Comma);
                else if (_currentToken.Kind != TokenKind.CloseParenthesis) break;
            }

            Eat(TokenKind.CloseParenthesis);
        }

        // Parse struct body: { field: Type, field2: Type2 }
        Eat(TokenKind.OpenBrace);

        var fields = new List<StructFieldNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var fieldType = ParseType();

            var fieldSpan = SourceSpan.Combine(fieldNameToken.Span, fieldType.Span);
            fields.Add(new StructFieldNode(fieldSpan, fieldNameToken.Text, fieldType));

            // Fields can be separated by commas or newlines (optional)
            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(structKeyword.Span, closeBrace.Span);
        return new StructDeclarationNode(span, nameToken.Text, typeParameters, fields);
    }

    /// <summary>
    /// Parses an enum declaration with optional generic type parameters and variants.
    /// </summary>
    /// <returns>An <see cref="EnumDeclarationNode"/> representing the enum definition.</returns>
    private EnumDeclarationNode ParseEnumDeclaration()
    {
        var enumKeyword = Eat(TokenKind.Enum);
        var nameToken = Eat(TokenKind.Identifier);

        // Parse optional generic type parameters: (T, U, V)
        var typeParameters = new List<string>();
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            Eat(TokenKind.OpenParenthesis);

            while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
            {
                var typeParam = Eat(TokenKind.Identifier);
                typeParameters.Add(typeParam.Text);

                if (_currentToken.Kind == TokenKind.Comma)
                    Eat(TokenKind.Comma);
                else if (_currentToken.Kind != TokenKind.CloseParenthesis) break;
            }

            Eat(TokenKind.CloseParenthesis);
        }

        // Parse enum body: { Variant, Variant(Type), Variant(T1, T2) }
        Eat(TokenKind.OpenBrace);

        var variants = new List<EnumVariantNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var variantNameToken = Eat(TokenKind.Identifier);

            // Check for payload types: Variant(Type1, Type2)
            var payloadTypes = new List<TypeNode>();
            SourceSpan variantEnd = variantNameToken.Span;
            if (_currentToken.Kind == TokenKind.OpenParenthesis)
            {
                Eat(TokenKind.OpenParenthesis);

                while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
                {
                    var payloadType = ParseType();
                    payloadTypes.Add(payloadType);

                    if (_currentToken.Kind == TokenKind.Comma)
                        Eat(TokenKind.Comma);
                    else if (_currentToken.Kind != TokenKind.CloseParenthesis) break;
                }

                var closeParen = Eat(TokenKind.CloseParenthesis);
                variantEnd = closeParen.Span;
            }

            var variantSpan = SourceSpan.Combine(variantNameToken.Span, variantEnd);
            variants.Add(new EnumVariantNode(variantSpan, variantNameToken.Text, payloadTypes));

            // Variants can be separated by commas or newlines (optional)
            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(enumKeyword.Span, closeBrace.Span);
        return new EnumDeclarationNode(span, nameToken.Text, typeParameters, variants);
    }

    /// <summary>
    /// Parses a function declaration with parameters, optional return type, and body.
    /// </summary>
    /// <param name="modifiers">Optional function modifiers (public, foreign, etc.).</param>
    /// <returns>A <see cref="FunctionDeclarationNode"/> representing the function.</returns>
    public FunctionDeclarationNode ParseFunction(FunctionModifiers modifiers = FunctionModifiers.None)
    {
        if (_currentToken.Kind == TokenKind.Pub)
        {
            Eat(TokenKind.Pub);
            modifiers |= FunctionModifiers.Public;
        }

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

            var paramSpan = SourceSpan.Combine(paramNameToken.Span, paramType.Span);
            parameters.Add(new FunctionParameterNode(paramSpan, paramNameToken.Text, paramType));

            // If there's a comma, consume it and continue parsing parameters
            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                // Error: expected comma or close parenthesis
                break;
        }

        Eat(TokenKind.CloseParenthesis);

        // Parse return type (optional for now, but expected in new syntax)
        TypeNode? returnType = null;
        if (_currentToken.Kind is TokenKind.Identifier or TokenKind.Ampersand or TokenKind.Dollar
            or TokenKind.OpenBracket or TokenKind.OpenParenthesis)
            returnType = ParseType();

        var statements = new List<StatementNode>();

        if (modifiers.HasFlag(FunctionModifiers.Foreign))
        {
            // Foreign functions have no body
            var span = SourceSpan.Combine(fnKeyword.Span, _currentToken.Span);
            return new FunctionDeclarationNode(span, identifier.Text, parameters, returnType, statements,
                modifiers | FunctionModifiers.Foreign);
        }
        else
        {
            Eat(TokenKind.OpenBrace);

            while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
            {
                try
                {
                    try
                    {
                        statements.Add(ParseStatement());
                    }
                    catch (ParserException ex)
                    {
                        _diagnostics.Add(ex.Diagnostic);
                        SynchronizeStatement();
                    }
                }
                catch (ParserException ex)
                {
                    _diagnostics.Add(ex.Diagnostic);
                    SynchronizeStatement();
                }
            }

            Eat(TokenKind.CloseBrace);

            var span = SourceSpan.Combine(fnKeyword.Span, _currentToken.Span);
            return new FunctionDeclarationNode(span, identifier.Text, parameters, returnType, statements, modifiers);
        }
    }

    /// <summary>
    /// Parses a test block declaration: test "name" { ... }
    /// </summary>
    /// <returns>A <see cref="TestDeclarationNode"/> representing the test block.</returns>
    private TestDeclarationNode ParseTest()
    {
        var testKeyword = Eat(TokenKind.Test);

        // Parse test name (must be a string literal)
        if (_currentToken.Kind != TokenKind.StringLiteral)
        {
            throw new ParserException(Diagnostic.Error(
                "expected string literal for test name",
                _currentToken.Span,
                $"found '{_currentToken.Text}'",
                "E1002"));
        }
        var testName = Eat(TokenKind.StringLiteral).Text;

        // Parse test body
        Eat(TokenKind.OpenBrace);

        var statements = new List<StatementNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            statements.Add(ParseStatement());
        }

        Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(testKeyword.Span, _currentToken.Span);
        return new TestDeclarationNode(span, testName, statements);
    }

    /// <summary>
    /// Parses a single statement (variable declaration, return, assignment, etc.).
    /// </summary>
    /// <returns>A <see cref="StatementNode"/> representing the parsed statement.</returns>
    private StatementNode ParseStatement()
    {
        switch (_currentToken.Kind)
        {
            case TokenKind.Let:
            case TokenKind.Const:
                return ParseVariableDeclaration();

            case TokenKind.Return:
            {
                var returnKeyword = Eat(TokenKind.Return);
                var expression = ParseExpression();
                var span = SourceSpan.Combine(returnKeyword.Span, expression.Span);
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

            case TokenKind.Defer:
            {
                var deferKeyword = Eat(TokenKind.Defer);
                var expression = ParseExpression();
                var span = SourceSpan.Combine(deferKeyword.Span, expression.Span);
                return new DeferStatementNode(span, expression);
            }

            case TokenKind.For:
                return ParseForLoop();

            case TokenKind.OpenBrace:
            {
                // Block statement - parse as expression statement
                var blockExpr = ParseBlockExpression();
                return new ExpressionStatementNode(blockExpr.Span, blockExpr);
            }

            case TokenKind.If:
            {
                // If statement - parse as expression statement
                var ifExpr = ParseIfExpression();
                return new ExpressionStatementNode(ifExpr.Span, ifExpr);
            }

            default:
                // Default: parse an expression as a statement (e.g., println(s))
                var expr = ParseExpression();
                return new ExpressionStatementNode(expr.Span, expr);
        }
    }

    /// <summary>
    /// Parses a variable declaration statement with optional type annotation and initializer.
    /// Supports both `let` (mutable) and `const` (immutable) declarations.
    /// </summary>
    /// <returns>A <see cref="VariableDeclarationNode"/> representing the variable declaration.</returns>
    private VariableDeclarationNode ParseVariableDeclaration()
    {
        // Accept either 'let' or 'const'
        var isConst = _currentToken.Kind == TokenKind.Const;
        var keyword = isConst ? Eat(TokenKind.Const) : Eat(TokenKind.Let);
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

        var span = SourceSpan.Combine(keyword.Span, _currentToken.Span);
        return new VariableDeclarationNode(span, identifier.Text, type, initializer, isConst);
    }

    /// <summary>
    /// Parses an expression starting from the lowest precedence level.
    /// </summary>
    /// <returns>An <see cref="ExpressionNode"/> representing the parsed expression.</returns>
    private ExpressionNode ParseExpression()
    {
        return ParseBinaryExpression(0);
    }

    /// <summary>
    /// Parses binary expressions using precedence climbing algorithm.
    /// </summary>
    /// <param name="parentPrecedence">The precedence level of the parent expression.</param>
    /// <returns>An <see cref="ExpressionNode"/> representing the binary expression tree.</returns>
    private ExpressionNode ParseBinaryExpression(int parentPrecedence)
    {
        var left = ParsePrimaryExpression();

        // Handle postfix operators (like .*)
        left = ParsePostfixOperators(left);

        // Handle cast chains: expr as Type as Type
        left = ParseCastChain(left);

        // Handle match expression: expr match { pattern => expr, ... }
        if (_currentToken.Kind == TokenKind.Match)
        {
            return ParseMatchExpression(left);
        }

        while (true)
        {
            // Check for assignment: lvalue = expression
            // Valid lvalues: identifiers and field access expressions
            if (_currentToken.Kind == TokenKind.Equals && IsValidLValue(left))
            {
                _currentToken = _lexer.NextToken();
                var value = ParseExpression(); // Right-associative, so parse full expression
                var assignSpan = SourceSpan.Combine(left.Span, value.Span);
                return new AssignmentExpressionNode(assignSpan, left, value);
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
                var rangeSpan = SourceSpan.Combine(left.Span, rangeEnd.Span);
                left = new RangeExpressionNode(rangeSpan, left, rangeEnd);
                continue;
            }

            // Special handling for null-coalescing operator (right-associative)
            if (operatorToken.Kind == TokenKind.QuestionQuestion)
            {
                _currentToken = _lexer.NextToken();
                // Right-associative: parse with same precedence to allow chaining a ?? b ?? c
                var coalesceRight = ParseBinaryExpression(precedence - 1);
                var coalesceSpan = SourceSpan.Combine(left.Span, coalesceRight.Span);
                left = new CoalesceExpressionNode(coalesceSpan, left, coalesceRight);
                continue;
            }

            BinaryOperatorKind operatorKind;
            try
            {
                operatorKind = GetBinaryOperatorKind(operatorToken.Kind);
            }
            catch (ParserException ex)
            {
                _diagnostics.Add(ex.Diagnostic);
                // Attempt to synchronize expression: skip until likely delimiter and produce dummy
                SynchronizeExpression();
                return new IntegerLiteralNode(operatorToken.Span, 0);
            }

            _currentToken = _lexer.NextToken();

            var right = ParseBinaryExpression(precedence);

            var span = SourceSpan.Combine(left.Span, right.Span);
            left = new BinaryExpressionNode(span, left, operatorKind, right);
        }

        return left;
    }

    /// <summary>
    /// Parses postfix operators such as field access, array indexing, function calls, and dereferencing.
    /// </summary>
    /// <param name="expr">The left-hand side expression to apply postfix operators to.</param>
    /// <returns>An <see cref="ExpressionNode"/> with postfix operators applied.</returns>
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
                    var span = SourceSpan.Combine(expr.Span, starToken.Span);
                    expr = new DereferenceExpressionNode(span, expr);
                    continue;
                }

                if (_currentToken.Kind == TokenKind.Identifier)
                {
                    // Field access or method call: obj.field or obj.method(args)
                    var fieldToken = Eat(TokenKind.Identifier);

                    // Check if this is a method call: obj.method(args)
                    if (_currentToken.Kind == TokenKind.OpenParenthesis)
                    {
                        Eat(TokenKind.OpenParenthesis);
                        var arguments = new List<ExpressionNode>();

                        // Parse arguments
                        while (_currentToken.Kind != TokenKind.CloseParenthesis &&
                               _currentToken.Kind != TokenKind.EndOfFile)
                        {
                            arguments.Add(ParseExpression());

                            if (_currentToken.Kind == TokenKind.Comma)
                                Eat(TokenKind.Comma);
                            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                                break;
                        }

                        var closeParenToken = Eat(TokenKind.CloseParenthesis);
                        var callSpan = SourceSpan.Combine(expr.Span, closeParenToken.Span);

                        // For EnumName.Variant(args) or UFCS obj.method(args):
                        // - syntheticName is "EnumName.Variant" or "obj.method" (for legacy enum construction lookup)
                        // - ufcsReceiver is the base expression (for UFCS transformation)
                        // - methodName is just "Variant" or "method" (the right side of the dot)
                        var syntheticName =
                            $"{(expr is IdentifierExpressionNode id ? id.Name : "_")}.{fieldToken.Text}";
                        expr = new CallExpressionNode(callSpan, syntheticName, arguments,
                            ufcsReceiver: expr, methodName: fieldToken.Text);
                        continue;
                    }

                    // Regular field access
                    var span = SourceSpan.Combine(expr.Span, fieldToken.Span);
                    expr = new MemberAccessExpressionNode(span, expr, fieldToken.Text);
                    continue;
                }

                _diagnostics.Add(Diagnostic.Error(
                    $"expected `*` or identifier after `.`",
                    dotToken.Span,
                    $"found '{_currentToken.Text}'",
                    "E1002"));
                break;
            }

            // Handle null-propagation operator: opt?.field
            if (_currentToken.Kind == TokenKind.QuestionDot)
            {
                var questionDotToken = Eat(TokenKind.QuestionDot);
                if (_currentToken.Kind == TokenKind.Identifier)
                {
                    var fieldToken = Eat(TokenKind.Identifier);
                    var span = SourceSpan.Combine(expr.Span, fieldToken.Span);
                    expr = new NullPropagationExpressionNode(span, expr, fieldToken.Text);
                    continue;
                }

                _diagnostics.Add(Diagnostic.Error(
                    $"expected identifier after `?.`",
                    questionDotToken.Span,
                    $"found '{_currentToken.Text}'",
                    "E1002"));
                break;
            }

            // Handle index operator: arr[i]
            if (_currentToken.Kind == TokenKind.OpenBracket)
            {
                var openBracket = Eat(TokenKind.OpenBracket);
                var index = ParseExpression();
                var closeBracket = Eat(TokenKind.CloseBracket);
                var span = SourceSpan.Combine(expr.Span, closeBracket.Span);
                expr = new IndexExpressionNode(span, expr, index);
                continue;
            }

            break;
        }

        return expr;
    }

    /// <summary>
    /// Parses a chain of cast expressions (e.g., expr as Type1 as Type2).
    /// </summary>
    /// <param name="expr">The expression to be cast.</param>
    /// <returns>An <see cref="ExpressionNode"/> with cast operations applied.</returns>
    private ExpressionNode ParseCastChain(ExpressionNode expr)
    {
        while (_currentToken.Kind == TokenKind.As)
        {
            var asToken = Eat(TokenKind.As);
            var targetType = ParseType();
            var span = SourceSpan.Combine(expr.Span, targetType.Span);
            expr = new CastExpressionNode(span, expr, targetType);
        }

        return expr;
    }

    /// <summary>
    /// Parses primary expressions (literals, identifiers, parenthesized expressions, unary operators, etc.).
    /// </summary>
    /// <returns>An <see cref="ExpressionNode"/> representing the primary expression.</returns>
    private ExpressionNode ParsePrimaryExpression()
    {
        switch (_currentToken.Kind)
        {
            case TokenKind.Ampersand:
            {
                // Address-of operator: &expr — binds after postfix (so &arr[0] means address-of (arr[0]))
                var ampToken = Eat(TokenKind.Ampersand);
                var targetPrimary = ParsePrimaryExpression();
                var targetWithPostfix = ParsePostfixOperators(targetPrimary);
                var span = SourceSpan.Combine(ampToken.Span, targetWithPostfix.Span);
                return new AddressOfExpressionNode(span, targetWithPostfix);
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

            case TokenKind.StringLiteral:
            {
                var stringToken = Eat(TokenKind.StringLiteral);
                return new StringLiteralNode(stringToken.Span, stringToken.Text);
            }

            case TokenKind.Null:
            {
                var nullToken = Eat(TokenKind.Null);
                return new NullLiteralNode(nullToken.Span);
            }

            case TokenKind.Dot:
            {
                var dotToken = Eat(TokenKind.Dot);
                if (_currentToken.Kind == TokenKind.OpenBrace)
                    return ParseAnonymousStructConstruction(dotToken);

                _diagnostics.Add(Diagnostic.Error(
                    "unexpected '.' in expression",
                    dotToken.Span,
                    "anonymous struct literals use .{ field = value }",
                    "E1001"));
                return new IntegerLiteralNode(dotToken.Span, 0);
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
                    while (_currentToken.Kind != TokenKind.CloseParenthesis &&
                           _currentToken.Kind != TokenKind.EndOfFile)
                    {
                        arguments.Add(ParseExpression());

                        // If there's a comma, consume it and continue parsing arguments
                        if (_currentToken.Kind == TokenKind.Comma)
                            Eat(TokenKind.Comma);
                        else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                            // Error: expected comma or close parenthesis
                            break;
                    }

                    var closeParenToken = Eat(TokenKind.CloseParenthesis);
                    var callSpan = SourceSpan.Combine(identifierToken.Span, closeParenToken.Span);
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
                SynchronizeExpression();
                _diagnostics.Add(Diagnostic.Error(
                    $"unexpected token '{_currentToken.Text}' in expression",
                    _currentToken.Span,
                    null,
                    "E1001"));
                // Return a dummy literal to allow further parsing
                return new IntegerLiteralNode(_currentToken.Span, 0);
        }
    }

    /// <summary>
    /// Gets the precedence level for a binary operator token.
    /// Higher values indicate higher precedence (tighter binding).
    /// </summary>
    /// <param name="kind">The token kind representing the binary operator.</param>
    /// <returns>The precedence level (0-6), or 0 if not a binary operator.</returns>
    private int GetBinaryOperatorPrecedence(TokenKind kind)
    {
        return kind switch
        {
            TokenKind.Star or TokenKind.Slash or TokenKind.Percent => 6,
            TokenKind.Plus or TokenKind.Minus => 5,
            TokenKind.DotDot => 4,
            TokenKind.LessThan or TokenKind.GreaterThan or TokenKind.LessThanOrEqual
                or TokenKind.GreaterThanOrEqual => 3,
            TokenKind.EqualsEquals or TokenKind.NotEquals => 2,
            TokenKind.QuestionQuestion => 1, // Lowest precedence, right-associative
            _ => 0
        };
    }

    /// <summary>
    /// Checks if an expression is a valid l-value (can appear on left side of assignment).
    /// </summary>
    /// <param name="expr">The expression to check.</param>
    /// <returns>True if the expression is a valid l-value, false otherwise.</returns>
    private bool IsValidLValue(ExpressionNode expr)
    {
        return expr is IdentifierExpressionNode or MemberAccessExpressionNode;
    }

    private sealed class ParserException : Exception
    {
        public ParserException(Diagnostic diagnostic)
        {
            Diagnostic = diagnostic;
        }

        public Diagnostic Diagnostic { get; }
    }

    /// <summary>
    /// Converts a token kind to its corresponding binary operator kind.
    /// </summary>
    /// <param name="kind">The token kind representing the operator.</param>
    /// <returns>The corresponding <see cref="BinaryOperatorKind"/>.</returns>
    /// <exception cref="ArgumentOutOfRangeException">Thrown if the token is not a valid binary operator.</exception>
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
            _ => throw new ParserException(Diagnostic.Error(
                $"unexpected operator token '{_currentToken.Text}'",
                _currentToken.Span,
                null,
                "E1001"))
        };
    }

    /// <summary>
    /// Parses an if expression with condition, then-branch, and optional else-branch.
    /// </summary>
    /// <returns>An <see cref="IfExpressionNode"/> representing the if expression.</returns>
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
        var span = SourceSpan.Combine(ifKeyword.Span, endPos);
        return new IfExpressionNode(span, condition, thenBranch, elseBranch);
    }

    /// <summary>
    /// Parses a struct construction expression with field initializers.
    /// </summary>
    /// <param name="typeName">The type of the struct being constructed.</param>
    /// <returns>A <see cref="StructConstructionExpressionNode"/> representing the struct construction.</returns>
    private StructConstructionExpressionNode ParseStructConstruction(TypeNode typeName)
    {
        var openBrace = Eat(TokenKind.OpenBrace);
        var fields = new List<(string, ExpressionNode)>();

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            if (_currentToken.Kind == TokenKind.Equals)
                Eat(TokenKind.Equals);
            else
                throw new ParserException(Diagnostic.Error(
                    "expected '=' in struct field",
                    _currentToken.Span,
                    "use `field = expr`",
                    "E1002"));
            var fieldValue = ParseExpression();

            fields.Add((fieldNameToken.Text, fieldValue));

            // Fields can be separated by commas
            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseBrace)
                // Allow newlines as separators too
                break;
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = SourceSpan.Combine(typeName.Span, closeBrace.Span);
        return new StructConstructionExpressionNode(span, typeName, fields);
    }

    /// <summary>
    /// Parses an anonymous struct construction expression (e.g., .{ field1 = value1, field2 = value2 }).
    /// </summary>
    /// <param name="dotToken">The dot token that starts the anonymous struct literal.</param>
    /// <returns>An <see cref="AnonymousStructExpressionNode"/> representing the anonymous struct.</returns>
    private AnonymousStructExpressionNode ParseAnonymousStructConstruction(Token dotToken)
    {
        var openBrace = Eat(TokenKind.OpenBrace);
        var fields = new List<(string, ExpressionNode)>();

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            if (_currentToken.Kind == TokenKind.Equals)
                Eat(TokenKind.Equals);
            else
                throw new ParserException(Diagnostic.Error(
                    "expected '=' in struct field",
                    _currentToken.Span,
                    "use `field = expr`",
                    "E1002"));
            var fieldValue = ParseExpression();

            fields.Add((fieldNameToken.Text, fieldValue));

            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseBrace)
                break;
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = SourceSpan.Combine(dotToken.Span, closeBrace.Span);
        return new AnonymousStructExpressionNode(span, fields);
    }

    /// <summary>
    /// Parses a block expression containing statements and an optional trailing expression.
    /// </summary>
    /// <returns>A <see cref="BlockExpressionNode"/> representing the block.</returns>
    private BlockExpressionNode ParseBlockExpression()
    {
        var openBrace = Eat(TokenKind.OpenBrace);
        var statements = new List<StatementNode>();
        ExpressionNode? trailingExpression = null;

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            // Check if this might be a trailing expression (no statement keywords)
            if (_currentToken.Kind != TokenKind.Let &&
                _currentToken.Kind != TokenKind.Const &&
                _currentToken.Kind != TokenKind.Return &&
                _currentToken.Kind != TokenKind.For &&
                _currentToken.Kind != TokenKind.Break &&
                _currentToken.Kind != TokenKind.Continue &&
                _currentToken.Kind != TokenKind.Defer &&
                _currentToken.Kind != TokenKind.OpenBrace &&
                _currentToken.Kind != TokenKind.If)
            {
                // Try to parse as expression
                var expr = ParseExpression();

                // If it's the last thing before }, it's a trailing expression
                if (_currentToken.Kind == TokenKind.CloseBrace)
                {
                    trailingExpression = expr;
                    break;
                }

                // Treat any expression as a statement (side effects or ignored value)
                statements.Add(new ExpressionStatementNode(expr.Span, expr));
                continue;
            }

            statements.Add(ParseStatement());
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = SourceSpan.Combine(openBrace.Span, closeBrace.Span);
        return new BlockExpressionNode(span, statements, trailingExpression);
    }

    /// <summary>
    /// Parses a for loop expression with an iterator variable and iterable expression.
    /// </summary>
    /// <returns>A <see cref="ForLoopNode"/> representing the for loop.</returns>
    private ForLoopNode ParseForLoop()
    {
        var forKeyword = Eat(TokenKind.For);
        Eat(TokenKind.OpenParenthesis);
        var iterator = Eat(TokenKind.Identifier);
        Eat(TokenKind.In);
        var iterable = ParseExpression();
        var closeParen = Eat(TokenKind.CloseParenthesis);

        var body = ParseExpression();

        // Span only includes "for (v in c)" part, not the body
        var span = SourceSpan.Combine(forKeyword.Span, closeParen.Span);
        return new ForLoopNode(span, iterator.Text, iterable, body);
    }

    /// <summary>
    /// Parses a type expression with support for references, generics, and nullable types.
    /// Grammar:
    /// type := prefix_type postfix*
    /// prefix_type := '&' prefix_type | primary_type
    /// primary_type := identifier generic_args?
    /// generic_args := '[' type (',' type)* ']'
    /// postfix := '?'
    /// Examples:
    /// i32, &i32, i32?, &i32?, List[i32], &List[i32]?, Dict[String, i32]
    /// </summary>
    private TypeNode ParseType()
    {
        var startSpan = _currentToken.Span;

        // Parse prefix operators (reference: &)
        TypeNode type;
        if (_currentToken.Kind == TokenKind.Ampersand)
        {
            var ampToken = Eat(TokenKind.Ampersand);
            var innerType = ParseType(); // Recursively parse for nested references
            var span = SourceSpan.Combine(ampToken.Span, innerType.Span);
            type = new ReferenceTypeNode(span, innerType);
        }
        else
        {
            // Parse primary type (named type, array, or generic)
            type = ParsePrimaryType();
        }

        // Parse postfix operators (nullable: ?, slice: [])
        while (true)
            if (_currentToken.Kind == TokenKind.Question)
            {
                var questionToken = Eat(TokenKind.Question);
                var span = SourceSpan.Combine(startSpan, questionToken.Span);
                type = new NullableTypeNode(span, type);
            }
            else if (_currentToken.Kind == TokenKind.OpenBracket && PeekNextToken().Kind == TokenKind.CloseBracket)
            {
                // T[] - slice type (only if next token is immediately ']')
                var openBracket = Eat(TokenKind.OpenBracket);
                var closeBracket = Eat(TokenKind.CloseBracket);
                var span = SourceSpan.Combine(startSpan, closeBracket.Span);
                type = new SliceTypeNode(span, type);
            }
            else
            {
                break;
            }

        return type;
    }

    /// <summary>
    /// Parses a primary type (identifier with optional generic arguments, or array type).
    /// Examples: i32, List[T], Dict[K, V], [i32; 5], $T
    /// </summary>
    private TypeNode ParsePrimaryType()
    {
        // Check for array type: [T; N]
        if (_currentToken.Kind == TokenKind.OpenBracket)
        {
            var openBracket = Eat(TokenKind.OpenBracket);
            var elementType = ParseType();
            Eat(TokenKind.Semicolon);

            // Consume the length token - check for integer type specifically for E1004
            var lengthToken = _currentToken;
            _currentToken = _lexer.NextToken();

            int length = 0;
            if (lengthToken.Kind != TokenKind.Integer || !int.TryParse(lengthToken.Text, out length))
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"invalid array length `{lengthToken.Text}`",
                    lengthToken.Span,
                    "array length must be an integer literal",
                    "E1004"));
            }

            var closeBracket = Eat(TokenKind.CloseBracket);

            var span = SourceSpan.Combine(openBracket.Span, closeBracket.Span);
            return new ArrayTypeNode(span, elementType, length);
        }

        // Generic parameter type: $T
        if (_currentToken.Kind == TokenKind.Dollar)
        {
            var dollar = Eat(TokenKind.Dollar);
            var ident = Eat(TokenKind.Identifier);
            var span = SourceSpan.Combine(dollar.Span, ident.Span);
            return new GenericParameterTypeNode(span, ident.Text);
        }

        var nameToken = Eat(TokenKind.Identifier);

        // Check for generic arguments using parentheses syntax: Type(arg1, arg2)
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            Eat(TokenKind.OpenParenthesis);
            var typeArgs = new List<TypeNode>();

            while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
            {
                typeArgs.Add(ParseType());

                if (_currentToken.Kind == TokenKind.Comma)
                    Eat(TokenKind.Comma);
                else if (_currentToken.Kind != TokenKind.CloseParenthesis) break;
            }

            var closeParen = Eat(TokenKind.CloseParenthesis);
            var span = SourceSpan.Combine(nameToken.Span, closeParen.Span);
            return new GenericTypeNode(span, nameToken.Text, typeArgs);
        }

        return new NamedTypeNode(nameToken.Span, nameToken.Text);
    }

    /// <summary>
    /// Peeks at the next token without consuming it.
    /// </summary>
    /// <returns>The next token that would be returned by advancing the parser.</returns>
    private Token PeekNextToken()
    {
        // Save current lexer state and get next token
        return _lexer.PeekNextToken();
    }

    /// <summary>
    /// Parses an array literal expression (e.g., [1, 2, 3] or []).
    /// </summary>
    /// <returns>An <see cref="ExpressionNode"/> representing the array literal.</returns>
    private ExpressionNode ParseArrayLiteral()
    {
        var openBracket = Eat(TokenKind.OpenBracket);

        // Empty array: []
        if (_currentToken.Kind == TokenKind.CloseBracket)
        {
            var closeBracket = Eat(TokenKind.CloseBracket);
            var span = SourceSpan.Combine(openBracket.Span, closeBracket.Span);
            return new ArrayLiteralExpressionNode(span, new List<ExpressionNode>());
        }

        // Parse first element
        var firstElement = ParseExpression();

        // Check if this is repeat syntax: [value; count]
        if (_currentToken.Kind == TokenKind.Semicolon)
        {
            Eat(TokenKind.Semicolon);

            // Consume the count token - check for integer type specifically for E1005
            var countToken = _currentToken;
            _currentToken = _lexer.NextToken();

            int count = 0;
            if (countToken.Kind != TokenKind.Integer || !int.TryParse(countToken.Text, out count))
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"invalid array repeat count `{countToken.Text}`",
                    countToken.Span,
                    "repeat count must be an integer literal",
                    "E1005"));
            }

            var closeBracket = Eat(TokenKind.CloseBracket);

            var span = SourceSpan.Combine(openBracket.Span, closeBracket.Span);
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
        var finalSpan = SourceSpan.Combine(openBracket.Span, closeBracketToken.Span);
        return new ArrayLiteralExpressionNode(finalSpan, elements);
    }

    /// <summary>
    /// Synchronizes the parser to a top-level construct after encountering an error.
    /// Skips tokens until a plausible recovery point (pub, struct, import, etc.) is found.
    /// </summary>
    private void SynchronizeTopLevel()
    {
        // Skip tokens until we hit a plausible top-level construct
        while (_currentToken.Kind != TokenKind.EndOfFile &&
               _currentToken.Kind != TokenKind.Pub &&
               _currentToken.Kind != TokenKind.Struct &&
               _currentToken.Kind != TokenKind.Import &&
               _currentToken.Kind != TokenKind.Hash)
        {
            _currentToken = _lexer.NextToken();
        }
    }

    /// <summary>
    /// Synchronizes the parser to a statement boundary after encountering an error.
    /// Skips tokens until a likely recovery point (let, const, return, if, etc.) is found.
    /// </summary>
    private void SynchronizeStatement()
    {
        // Skip tokens until we reach a likely statement boundary
        while (_currentToken.Kind != TokenKind.EndOfFile &&
               _currentToken.Kind != TokenKind.CloseBrace &&
               _currentToken.Kind != TokenKind.Let &&
               _currentToken.Kind != TokenKind.Const &&
               _currentToken.Kind != TokenKind.Return &&
               _currentToken.Kind != TokenKind.For &&
               _currentToken.Kind != TokenKind.Break &&
               _currentToken.Kind != TokenKind.Continue &&
               _currentToken.Kind != TokenKind.Defer &&
               _currentToken.Kind != TokenKind.If &&
               _currentToken.Kind != TokenKind.OpenBrace)
        {
            _currentToken = _lexer.NextToken();
        }
    }

    /// <summary>
    /// Synchronizes the parser to an expression boundary after encountering an error.
    /// Skips tokens until a delimiter (parenthesis, bracket, comma, etc.) is found.
    /// </summary>
    private void SynchronizeExpression()
    {
        // Skip tokens until we hit a delimiter that likely ends an expression
        while (_currentToken.Kind != TokenKind.EndOfFile &&
               _currentToken.Kind != TokenKind.CloseParenthesis &&
               _currentToken.Kind != TokenKind.CloseBracket &&
               _currentToken.Kind != TokenKind.CloseBrace &&
               _currentToken.Kind != TokenKind.Comma)
        {
            _currentToken = _lexer.NextToken();
        }
    }

    /// <summary>
    /// Parses a match expression with pattern matching arms.
    /// </summary>
    /// <param name="scrutinee">The expression being matched against.</param>
    /// <returns>A <see cref="MatchExpressionNode"/> representing the match expression.</returns>
    private MatchExpressionNode ParseMatchExpression(ExpressionNode scrutinee)
    {
        var matchToken = Eat(TokenKind.Match);
        Eat(TokenKind.OpenBrace);

        var arms = new List<MatchArmNode>();

        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var armStart = _currentToken.Span;

            // Parse pattern
            var pattern = ParsePattern();

            // Expect =>
            Eat(TokenKind.FatArrow);

            // Parse result expression
            var resultExpr = ParseExpression();

            var armSpan = SourceSpan.Combine(armStart, resultExpr.Span);
            arms.Add(new MatchArmNode(armSpan, pattern, resultExpr));

            // Arms can be separated by commas (optional)
            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(scrutinee.Span, closeBrace.Span);
        return new MatchExpressionNode(span, scrutinee, arms);
    }

    /// <summary>
    /// Parses a pattern for use in match expressions (literals, wildcards, enum variants, destructuring).
    /// </summary>
    /// <param name="isSubPattern">True if parsing a sub-pattern within a larger pattern.</param>
    /// <returns>A <see cref="PatternNode"/> representing the parsed pattern.</returns>
    private PatternNode ParsePattern(bool isSubPattern = false)
    {
        var start = _currentToken.Span;

        // Check for wildcard pattern: _
        if (_currentToken.Kind == TokenKind.Underscore)
        {
            var underscoreToken = Eat(TokenKind.Underscore);
            return new WildcardPatternNode(underscoreToken.Span);
        }

        // Check for else pattern
        if (_currentToken.Kind == TokenKind.Else)
        {
            var elseToken = Eat(TokenKind.Else);
            return new ElsePatternNode(elseToken.Span);
        }

        // Check for identifier pattern (variable binding or enum variant)
        if (_currentToken.Kind == TokenKind.Identifier)
        {
            var firstIdent = Eat(TokenKind.Identifier);

            // Check for qualified variant: EnumName.Variant
            if (_currentToken.Kind == TokenKind.Dot)
            {
                Eat(TokenKind.Dot);
                var variantToken = Eat(TokenKind.Identifier);

                // Check for payload: Variant(pattern, pattern)
                var subPatterns = new List<PatternNode>();
                SourceSpan endSpan = variantToken.Span;
                if (_currentToken.Kind == TokenKind.OpenParenthesis)
                {
                    Eat(TokenKind.OpenParenthesis);

                    while (_currentToken.Kind != TokenKind.CloseParenthesis &&
                           _currentToken.Kind != TokenKind.EndOfFile)
                    {
                        subPatterns.Add(ParsePattern(isSubPattern: true));

                        if (_currentToken.Kind == TokenKind.Comma)
                            Eat(TokenKind.Comma);
                        else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                            break;
                    }

                    var closeParen = Eat(TokenKind.CloseParenthesis);
                    endSpan = closeParen.Span;
                }

                var span = SourceSpan.Combine(start, endSpan);
                return new EnumVariantPatternNode(span, firstIdent.Text, variantToken.Text, subPatterns);
            }

            // Check for short-form variant with payload: Variant(pattern, pattern)
            if (_currentToken.Kind == TokenKind.OpenParenthesis)
            {
                Eat(TokenKind.OpenParenthesis);

                var subPatterns = new List<PatternNode>();
                while (_currentToken.Kind != TokenKind.CloseParenthesis &&
                       _currentToken.Kind != TokenKind.EndOfFile)
                {
                    subPatterns.Add(ParsePattern(isSubPattern: true));

                    if (_currentToken.Kind == TokenKind.Comma)
                        Eat(TokenKind.Comma);
                    else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                        break;
                }

                var closeParen = Eat(TokenKind.CloseParenthesis);
                var span = SourceSpan.Combine(start, closeParen.Span);
                return new EnumVariantPatternNode(span, null, firstIdent.Text, subPatterns);
            }

            // Simple identifier: could be unit variant OR variable binding
            // If we're inside a variant's payload patterns, treat as variable binding
            // Otherwise, let type checker distinguish (treat as enum variant pattern)
            if (isSubPattern)
            {
                return new VariablePatternNode(firstIdent.Span, firstIdent.Text);
            }
            else
            {
                // Top-level pattern: could be unit variant or binding (type checker decides)
                return new EnumVariantPatternNode(firstIdent.Span, null, firstIdent.Text, new List<PatternNode>());
            }
        }

        _diagnostics.Add(Diagnostic.Error(
            $"expected pattern",
            _currentToken.Span,
            "patterns can be: _, identifier, or EnumName.Variant",
            "E1001"));
        return new WildcardPatternNode(_currentToken.Span);
    }

    /// <summary>
    /// Consumes the current token if it matches the expected kind, otherwise throws a parser exception.
    /// </summary>
    /// <param name="kind">The expected token kind.</param>
    /// <returns>The consumed token.</returns>
    /// <exception cref="ParserException">Thrown if the current token does not match the expected kind.</exception>
    private Token Eat(TokenKind kind)
    {
        var token = _currentToken;
        if (token.Kind != kind)
        {
            var diag = Diagnostic.Error(
                $"expected `{kind}`",
                token.Span,
                $"found '{token.Text}'",
                "E1002");
            // Signal an error to be caught by a higher-level parse routine
            throw new ParserException(diag);
        }

        _currentToken = _lexer.NextToken();
        return token;
    }
}