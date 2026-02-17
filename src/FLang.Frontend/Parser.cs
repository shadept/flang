using System.Numerics;
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
    private bool _stopAtBrace; // When true, '{' terminates expression parsing (used for if/for conditions)

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
        var globalConstants = new List<VariableDeclarationNode>();

        // Parse imports
        while (_currentToken.Kind == TokenKind.Import) imports.Add(ParseImport());

        // Parse structs, functions, tests, and global constants
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            try
            {
                // Parse leading directives (e.g., #foreign, #deprecated("msg"))
                var directives = ParseDirectives();

                if (_currentToken.Kind == TokenKind.Pub)
                {
                    // Could be struct, enum, type, function, or const - peek ahead
                    var nextToken = PeekNextToken();
                    if (nextToken.Kind == TokenKind.Struct)
                    {
                        Eat(TokenKind.Pub);
                        structs.Add(ParseStruct(directives));
                    }
                    else if (nextToken.Kind == TokenKind.Enum)
                    {
                        Eat(TokenKind.Pub);
                        enums.Add(ParseEnumDeclaration(directives));
                    }
                    else if (nextToken.Kind == TokenKind.Identifier && nextToken.Text == "type")
                    {
                        Eat(TokenKind.Pub);
                        var decl = ParseTypeDeclaration(directives);
                        if (decl is StructDeclarationNode s) structs.Add(s);
                        else if (decl is EnumDeclarationNode e) enums.Add(e);
                    }
                    else if (nextToken.Kind == TokenKind.Fn)
                    {
                        functions.Add(ParseFunction(directives: directives));
                    }
                    else if (nextToken.Kind == TokenKind.Const)
                    {
                        if (directives.Count > 0)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                "directives are not supported on const declarations",
                                directives[0].Span,
                                code: "E1001"));
                        }
                        Eat(TokenKind.Pub);
                        globalConstants.Add(ParseVariableDeclaration(isPublic: true));
                    }
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"expected `struct`, `enum`, `type`, `fn`, or `const` after `pub`",
                            _currentToken.Span,
                            $"found '{nextToken.Text}'",
                            "E1002"));
                        // Consume `pub` to prevent infinite loop and continue
                        _currentToken = _lexer.NextToken();
                    }
                }
                else if (_currentToken.Kind == TokenKind.Struct)
                {
                    structs.Add(ParseStruct(directives));
                }
                else if (_currentToken.Kind == TokenKind.Enum)
                {
                    enums.Add(ParseEnumDeclaration(directives));
                }
                else if (_currentToken.Kind == TokenKind.Identifier && _currentToken.Text == "type")
                {
                    var decl = ParseTypeDeclaration(directives);
                    if (decl is StructDeclarationNode s) structs.Add(s);
                    else if (decl is EnumDeclarationNode e) enums.Add(e);
                }
                else if (_currentToken.Kind == TokenKind.Fn)
                {
                    functions.Add(ParseFunction(directives: directives));
                }
                else if (_currentToken.Kind == TokenKind.Test)
                {
                    if (directives.Count > 0)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "directives are not supported on test blocks",
                            directives[0].Span,
                            code: "E1001"));
                    }
                    tests.Add(ParseTest());
                }
                else if (_currentToken.Kind == TokenKind.Const)
                {
                    if (directives.Count > 0)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "directives are not supported on const declarations",
                            directives[0].Span,
                            code: "E1001"));
                    }
                    globalConstants.Add(ParseVariableDeclaration());
                }
                else if (directives.Count > 0)
                {
                    // Directives were parsed but no declaration follows
                    _diagnostics.Add(Diagnostic.Error(
                        "expected declaration after directive(s)",
                        _currentToken.Span,
                        "directives must precede `struct`, `enum`, `type`, or `fn`",
                        "E1001"));
                    // Skip token to avoid infinite loop
                    if (_currentToken.Kind != TokenKind.EndOfFile)
                        _currentToken = _lexer.NextToken();
                }
                else
                {
                    // Unexpected token: report and attempt to recover by skipping it
                    _diagnostics.Add(Diagnostic.Error(
                        $"unexpected token '{_currentToken.Text}'",
                        _currentToken.Span,
                        "expected `struct`, `enum`, `type`, `pub fn`, `fn`, `test`, `const`, or directive",
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
        return new ModuleNode(span, imports, structs, enums, functions, tests, globalConstants);
    }

    /// <summary>
    /// Parses zero or more directives: #name or #name(arg1, arg2, ...).
    /// Arguments can be string literals, identifiers, or integers.
    /// </summary>
    private List<DirectiveNode> ParseDirectives()
    {
        var directives = new List<DirectiveNode>();
        while (_currentToken.Kind == TokenKind.Hash)
        {
            var hashToken = Eat(TokenKind.Hash);
            var nameToken = Eat(TokenKind.Identifier);

            var arguments = new List<Token>();
            if (_currentToken.Kind == TokenKind.OpenParenthesis)
            {
                Eat(TokenKind.OpenParenthesis);
                while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
                {
                    if (_currentToken.Kind is TokenKind.StringLiteral or TokenKind.Identifier or TokenKind.Integer)
                    {
                        arguments.Add(_currentToken);
                        _currentToken = _lexer.NextToken();
                    }
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "expected string literal, identifier, or integer in directive arguments",
                            _currentToken.Span,
                            $"found '{_currentToken.Text}'",
                            "E1002"));
                        break;
                    }

                    if (_currentToken.Kind == TokenKind.Comma)
                        Eat(TokenKind.Comma);
                    else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                        break;
                }
                var closeParen = Eat(TokenKind.CloseParenthesis);
                var span = SourceSpan.Combine(hashToken.Span, closeParen.Span);
                directives.Add(new DirectiveNode(span, nameToken.Text, arguments));
            }
            else
            {
                var span = SourceSpan.Combine(hashToken.Span, nameToken.Span);
                directives.Add(new DirectiveNode(span, nameToken.Text, arguments));
            }
        }
        return directives;
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
        var lastIdentifier = firstIdentifier;

        // Parse additional path components (e.g., std.io.File)
        while (_currentToken.Kind == TokenKind.Dot)
        {
            Eat(TokenKind.Dot);
            lastIdentifier = EatIdentifierOrKeyword();
            path.Add(lastIdentifier.Text);
        }

        var moduleSpan = SourceSpan.Combine(firstIdentifier.Span, lastIdentifier.Span);
        var span = SourceSpan.Combine(importKeyword.Span, lastIdentifier.Span);
        return new ImportDeclarationNode(span, moduleSpan, path);
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
    private StructDeclarationNode ParseStruct(List<DirectiveNode>? directives = null)
    {
        var structKeyword = Eat(TokenKind.Struct);

        _diagnostics.Add(Diagnostic.Error(
            "`struct Name { ... }` syntax has been removed, use `type Name = struct { ... }` instead",
            structKeyword.Span,
            hint: "replace with `type` declaration syntax",
            code: "E1050"));

        var nameToken = Eat(TokenKind.Identifier);

        // Parse type parameters (on struct keyword in new syntax, but here for error recovery)
        var typeParameters = ParseTypeParameters();

        return ParseStructBody(nameToken.Text, nameToken.Span, typeParameters, structKeyword.Span, directives);
    }

    private StructDeclarationNode ParseStructBody(string name, SourceSpan nameSpan, List<string> typeParameters, SourceSpan startSpan, List<DirectiveNode>? directives)
    {
        // Parse struct body: { field: Type, field2: Type2 }
        Eat(TokenKind.OpenBrace);

        var fields = new List<StructFieldNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var fieldType = ParseType();

            var fieldSpan = SourceSpan.Combine(fieldNameToken.Span, fieldType.Span);
            fields.Add(new StructFieldNode(fieldSpan, fieldNameToken.Span, fieldNameToken.Text, fieldType));

            // Fields can be separated by commas or newlines (optional)
            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var effectiveStart = directives is { Count: > 0 } ? directives[0].Span : startSpan;
        var span = SourceSpan.Combine(effectiveStart, closeBrace.Span);
        return new StructDeclarationNode(span, nameSpan, name, typeParameters, fields, directives);
    }

    /// <summary>
    /// Parses an enum declaration with optional generic type parameters and variants.
    /// </summary>
    /// <returns>An <see cref="EnumDeclarationNode"/> representing the enum definition.</returns>
    private EnumDeclarationNode ParseEnumDeclaration(List<DirectiveNode>? directives = null)
    {
        var enumKeyword = Eat(TokenKind.Enum);

        _diagnostics.Add(Diagnostic.Error(
            "`enum Name { ... }` syntax has been removed, use `type Name = enum { ... }` instead",
            enumKeyword.Span,
            hint: "replace with `type` declaration syntax",
            code: "E1051"));

        var nameToken = Eat(TokenKind.Identifier);

        // Parse type parameters for error recovery
        var typeParameters = ParseTypeParameters();

        return ParseEnumBody(nameToken.Text, nameToken.Span, typeParameters, enumKeyword.Span, directives);
    }

    private EnumDeclarationNode ParseEnumBody(string name, SourceSpan nameSpan, List<string> typeParameters, SourceSpan startSpan, List<DirectiveNode>? directives)
    {
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

            // Check for explicit tag value: Variant = <integer>
            long? explicitTagValue = null;
            if (_currentToken.Kind == TokenKind.Equals)
            {
                Eat(TokenKind.Equals);
                bool negative = false;
                if (_currentToken.Kind == TokenKind.Minus)
                {
                    Eat(TokenKind.Minus);
                    negative = true;
                }
                var intToken = Eat(TokenKind.Integer);
                variantEnd = intToken.Span;
                explicitTagValue = long.Parse(intToken.Text);
                if (negative) explicitTagValue = -explicitTagValue;
            }

            var variantSpan = SourceSpan.Combine(variantNameToken.Span, variantEnd);
            variants.Add(new EnumVariantNode(variantSpan, variantNameToken.Span, variantNameToken.Text, payloadTypes, explicitTagValue));

            // Variants can be separated by commas or newlines (optional)
            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);

        var effectiveStart = directives is { Count: > 0 } ? directives[0].Span : startSpan;
        var span = SourceSpan.Combine(effectiveStart, closeBrace.Span);
        return new EnumDeclarationNode(span, nameSpan, name, typeParameters, variants, directives);
    }

    private List<string> ParseTypeParameters()
    {
        var typeParameters = new List<string>();
        if (_currentToken.Kind != TokenKind.OpenParenthesis) return typeParameters;

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
        return typeParameters;
    }

    /// <summary>
    /// Parses a type declaration: type Name = struct { ... } or type Name = enum { ... }
    /// </summary>
    private object ParseTypeDeclaration(List<DirectiveNode>? directives = null)
    {
        var typeKeyword = Eat(TokenKind.Identifier); // contextual keyword "type"
        var nameToken = Eat(TokenKind.Identifier);

        // Type parameters on the name is now an error — they belong on struct/enum
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            _diagnostics.Add(Diagnostic.Error(
                "type parameters belong on `struct`/`enum`, not the type name",
                _currentToken.Span,
                hint: $"use `type {nameToken.Text} = struct(...) {{ ... }}` instead",
                code: "E1052"));
            ParseTypeParameters(); // consume for error recovery
        }

        Eat(TokenKind.Equals);

        if (_currentToken.Kind == TokenKind.Struct)
        {
            Eat(TokenKind.Struct);
            var typeParameters = ParseTypeParameters();
            return ParseStructBody(nameToken.Text, nameToken.Span, typeParameters, typeKeyword.Span, directives);
        }

        if (_currentToken.Kind == TokenKind.Enum)
        {
            Eat(TokenKind.Enum);
            var typeParameters = ParseTypeParameters();
            return ParseEnumBody(nameToken.Text, nameToken.Span, typeParameters, typeKeyword.Span, directives);
        }

        _diagnostics.Add(Diagnostic.Error(
            $"expected `struct` or `enum` after `=` in type declaration",
            _currentToken.Span,
            $"found '{_currentToken.Text}'",
            "E1002"));

        // Return a dummy struct node to avoid null
        return ParseStructBody(nameToken.Text, nameToken.Span, [], typeKeyword.Span, directives);
    }

    /// <summary>
    /// Parses a function declaration with parameters, optional return type, and body.
    /// </summary>
    /// <param name="modifiers">Optional function modifiers (public, foreign, etc.).</param>
    /// <returns>A <see cref="FunctionDeclarationNode"/> representing the function.</returns>
    public FunctionDeclarationNode ParseFunction(FunctionModifiers modifiers = FunctionModifiers.None,
        List<DirectiveNode>? directives = null)
    {
        directives ??= [];

        // Derive modifiers from directives
        foreach (var d in directives)
        {
            if (d.Name == "foreign") modifiers |= FunctionModifiers.Foreign;
            else if (d.Name == "inline") modifiers |= FunctionModifiers.Inline;
        }

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
        bool hasSeenDefault = false;
        bool hasSeenVariadic = false;
        while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
        {
            // Check for variadic prefix: ..name
            bool isVariadic = false;
            if (_currentToken.Kind == TokenKind.DotDot)
            {
                Eat(TokenKind.DotDot);
                isVariadic = true;
            }

            var paramNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var paramType = ParseType();

            // Check for default value: name: Type = expr
            ExpressionNode? defaultValue = null;
            if (_currentToken.Kind == TokenKind.Equals)
            {
                Eat(TokenKind.Equals);
                defaultValue = ParseExpression();

                if (isVariadic)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "variadic parameter cannot have a default value",
                        paramNameToken.Span,
                        "remove the default value or the '..' prefix",
                        "E2060"));
                }
            }

            if (isVariadic)
            {
                if (hasSeenVariadic)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "only one variadic parameter is allowed",
                        paramNameToken.Span,
                        "remove the extra '..' prefix",
                        "E2061"));
                }
                hasSeenVariadic = true;
            }
            else if (hasSeenVariadic)
            {
                _diagnostics.Add(Diagnostic.Error(
                    "no parameters are allowed after a variadic parameter",
                    paramNameToken.Span,
                    "move this parameter before the variadic parameter",
                    "E2062"));
            }

            if (defaultValue != null)
                hasSeenDefault = true;
            else if (hasSeenDefault && !isVariadic)
            {
                _diagnostics.Add(Diagnostic.Error(
                    "required parameter cannot follow a parameter with a default value",
                    paramNameToken.Span,
                    "add a default value or reorder parameters",
                    "E2063"));
            }

            var paramSpan = SourceSpan.Combine(paramNameToken.Span,
                defaultValue?.Span ?? paramType.Span);
            parameters.Add(new FunctionParameterNode(paramSpan, paramNameToken.Span, paramNameToken.Text,
                paramType, defaultValue, isVariadic));

            // If there's a comma, consume it and continue parsing parameters
            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                // Error: expected comma or close parenthesis
                break;
        }

        var closeParen = Eat(TokenKind.CloseParenthesis);

        // Parse return type (optional for now, but expected in new syntax)
        TypeNode? returnType = null;
        if (_currentToken.Kind is TokenKind.Identifier or TokenKind.Ampersand or TokenKind.Dollar
            or TokenKind.OpenBracket or TokenKind.OpenParenthesis or TokenKind.Fn
            or TokenKind.Struct or TokenKind.Enum)
            returnType = ParseType();

        var statements = new List<StatementNode>();

        // Foreign functions cannot have FLang-style variadic or default params
        if (modifiers.HasFlag(FunctionModifiers.Foreign) && hasSeenVariadic)
        {
            _diagnostics.Add(Diagnostic.Error(
                "foreign functions cannot have variadic parameters",
                identifier.Span,
                "use C-style variadic calling conventions instead",
                "E2064"));
        }

        var spanStart = directives.Count > 0 ? directives[0].Span : fnKeyword.Span;
        if (modifiers.HasFlag(FunctionModifiers.Foreign))
        {
            // Foreign functions have no body
            var fnSpan = SourceSpan.Combine(spanStart, returnType?.Span ?? closeParen.Span);
            return new FunctionDeclarationNode(fnSpan, identifier.Span, identifier.Text, parameters, returnType, statements,
                modifiers | FunctionModifiers.Foreign, directives);
        }
        else
        {
            Eat(TokenKind.OpenBrace);

            while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
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

            var closeBrace = Eat(TokenKind.CloseBrace);
            var fnSpan = SourceSpan.Combine(spanStart, closeBrace.Span);
            return new FunctionDeclarationNode(fnSpan, identifier.Span, identifier.Text, parameters, returnType, statements, modifiers, directives);
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

        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(testKeyword.Span, closeBrace.Span);
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
                    // Allow bare `return` for void functions - check if next token can't start an expression
                    if (IsBareReturn(_currentToken.Kind))
                    {
                        return new ReturnStatementNode(returnKeyword.Span, null);
                    }
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

            case TokenKind.Loop:
                return ParseLoop();

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
    /// <param name="isPublic">Whether this is a public declaration (for top-level constants).</param>
    /// <returns>A <see cref="VariableDeclarationNode"/> representing the variable declaration.</returns>
    private VariableDeclarationNode ParseVariableDeclaration(bool isPublic = false)
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

        var lastSpan = initializer?.Span ?? type?.Span ?? identifier.Span;
        var span = SourceSpan.Combine(keyword.Span, lastSpan);
        return new VariableDeclarationNode(span, identifier.Span, identifier.Text, type, initializer, isConst, isPublic);
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

                // Check if end is omitted (x..) - next token is a delimiter
                ExpressionNode? rangeEnd = null;
                if (!IsRangeDelimiter(_currentToken.Kind))
                {
                    rangeEnd = ParseBinaryExpression(precedence);
                }

                var rangeSpan = rangeEnd != null
                    ? SourceSpan.Combine(left.Span, rangeEnd.Span)
                    : SourceSpan.Combine(left.Span, operatorToken.Span);
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
                        var arguments = ParseCallArguments();
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

                // Tuple field access: t.0, t.1, etc. - desugars to t._0, t._1, etc.
                if (_currentToken.Kind == TokenKind.Integer)
                {
                    var indexToken = Eat(TokenKind.Integer);
                    var fieldName = $"_{indexToken.Text}";
                    var span = SourceSpan.Combine(expr.Span, indexToken.Span);
                    expr = new MemberAccessExpressionNode(span, expr, fieldName);
                    continue;
                }

                _diagnostics.Add(Diagnostic.Error(
                    $"expected `*`, identifier, or integer after `.`",
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

            case TokenKind.Minus:
                {
                    var minusToken = Eat(TokenKind.Minus);

                    // Special case: negative integer literal (e.g., -9223372036854775808i64)
                    // Parse the minus and integer together to support i64 min value
                    if (_currentToken.Kind == TokenKind.Integer)
                    {
                        var integerToken = Eat(TokenKind.Integer);
                        var (value, suffix) = ParseIntegerLiteralValue(integerToken.Text);
                        var span = SourceSpan.Combine(minusToken.Span, integerToken.Span);
                        return new IntegerLiteralNode(span, -value, suffix);
                    }

                    // General unary negation: -expr
                    var operandPrimary = ParsePrimaryExpression();
                    var operandWithPostfix = ParsePostfixOperators(operandPrimary);
                    var span2 = SourceSpan.Combine(minusToken.Span, operandWithPostfix.Span);
                    return new UnaryExpressionNode(span2, UnaryOperatorKind.Negate, operandWithPostfix);
                }

            case TokenKind.Bang:
                {
                    // Logical not: !expr
                    var bangToken = Eat(TokenKind.Bang);
                    var operandPrimary = ParsePrimaryExpression();
                    var operandWithPostfix = ParsePostfixOperators(operandPrimary);
                    var span = SourceSpan.Combine(bangToken.Span, operandWithPostfix.Span);
                    return new UnaryExpressionNode(span, UnaryOperatorKind.Not, operandWithPostfix);
                }

            case TokenKind.DotDot:
                {
                    // Prefix range: ..end or .. (unbounded)
                    var dotDotToken = Eat(TokenKind.DotDot);

                    // Check if there's an end expression (not followed by delimiter)
                    ExpressionNode? rangeEnd = null;
                    if (!IsRangeDelimiter(_currentToken.Kind))
                    {
                        rangeEnd = ParseBinaryExpression(0);
                    }

                    var span = rangeEnd != null
                        ? SourceSpan.Combine(dotDotToken.Span, rangeEnd.Span)
                        : dotDotToken.Span;
                    return new RangeExpressionNode(span, null, rangeEnd);
                }

            case TokenKind.Integer:
                {
                    var integerToken = Eat(TokenKind.Integer);
                    var (value, suffix) = ParseIntegerLiteralValue(integerToken.Text);
                    return new IntegerLiteralNode(integerToken.Span, value, suffix);
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

            case TokenKind.CharLiteral:
                {
                    var charToken = Eat(TokenKind.CharLiteral);
                    var codepoint = BigInteger.Parse(charToken.Text);
                    return new IntegerLiteralNode(charToken.Span, codepoint, "char");
                }

            case TokenKind.ByteLiteral:
                {
                    var byteToken = Eat(TokenKind.ByteLiteral);
                    var byteValue = BigInteger.Parse(byteToken.Text);
                    return new IntegerLiteralNode(byteToken.Span, byteValue, "u8");
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
                    if (_currentToken.Kind == TokenKind.OpenBrace && !_stopAtBrace)
                    {
                        // Parse as struct construction
                        var typeName = new NamedTypeNode(identifierToken.Span, identifierToken.Text);
                        return ParseStructConstruction(typeName);
                    }

                    // Check if this is a function call
                    if (_currentToken.Kind == TokenKind.OpenParenthesis)
                    {
                        Eat(TokenKind.OpenParenthesis);
                        var arguments = ParseCallArguments();
                        var closeParenToken = Eat(TokenKind.CloseParenthesis);
                        var callSpan = SourceSpan.Combine(identifierToken.Span, closeParenToken.Span);
                        return new CallExpressionNode(callSpan, identifierToken.Text, arguments);
                    }

                    return new IdentifierExpressionNode(identifierToken.Span, identifierToken.Text);
                }

            case TokenKind.OpenParenthesis:
                {
                    return ParseTupleOrGroupedExpression();
                }

            case TokenKind.If:
                return ParseIfExpression();

            case TokenKind.OpenBrace:
                if (_stopAtBrace) goto default; // '{' terminates condition parsing in if/for without parens
                return ParseBlockExpression();

            case TokenKind.OpenBracket:
                return ParseArrayLiteral();

            case TokenKind.Fn:
                return ParseLambdaExpression();

            default:
                var errorToken = _currentToken;
                SynchronizeExpression();
                // If we didn't make progress (stuck on same token), skip it to prevent infinite loop
                if (_currentToken.Kind == errorToken.Kind && _currentToken.Span.Index == errorToken.Span.Index)
                {
                    _currentToken = _lexer.NextToken();
                }
                _diagnostics.Add(Diagnostic.Error(
                    $"unexpected token '{errorToken.Text}' in expression",
                    errorToken.Span,
                    null,
                    "E1001"));
                // Return a dummy literal to allow further parsing
                return new IntegerLiteralNode(errorToken.Span, 0);
        }
    }

    private LambdaExpressionNode ParseLambdaExpression()
    {
        var fnKeyword = Eat(TokenKind.Fn);
        Eat(TokenKind.OpenParenthesis);

        var parameters = new List<LambdaExpressionNode.LambdaParameter>();
        while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var paramNameToken = Eat(TokenKind.Identifier);
            TypeNode? paramType = null;

            // If next token is ':', parse explicit type
            if (_currentToken.Kind == TokenKind.Colon)
            {
                Eat(TokenKind.Colon);
                paramType = ParseType();
            }

            parameters.Add(new LambdaExpressionNode.LambdaParameter(paramNameToken.Span, paramNameToken.Text, paramType));

            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                break;
        }

        Eat(TokenKind.CloseParenthesis);

        // Parse optional return type (same logic as ParseFunction)
        TypeNode? returnType = null;
        if (_currentToken.Kind is TokenKind.Identifier or TokenKind.Ampersand or TokenKind.Dollar
            or TokenKind.OpenBracket or TokenKind.OpenParenthesis or TokenKind.Fn
            or TokenKind.Struct or TokenKind.Enum)
            returnType = ParseType();

        // Parse body
        Eat(TokenKind.OpenBrace);
        var statements = new List<StatementNode>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
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
        var closeBrace = Eat(TokenKind.CloseBrace);

        var span = SourceSpan.Combine(fnKeyword.Span, closeBrace.Span);
        return new LambdaExpressionNode(span, parameters, returnType, statements);
    }

    /// <summary>
    /// Gets the precedence level for a binary operator token.
    /// Higher values indicate higher precedence (tighter binding).
    /// </summary>
    /// <param name="kind">The token kind representing the binary operator.</param>
    /// <returns>The precedence level, or 0 if not a binary operator.</returns>
    private static int GetBinaryOperatorPrecedence(TokenKind kind)
    {
        return kind switch
        {
            TokenKind.Star or TokenKind.Slash or TokenKind.Percent => 12,
            TokenKind.Plus or TokenKind.Minus => 11,
            TokenKind.ShiftLeft or TokenKind.ShiftRight or TokenKind.UnsignedShiftRight => 10,
            TokenKind.Ampersand => 9, // Bitwise AND (above comparisons, like C/Rust)
            TokenKind.Caret => 8,     // Bitwise XOR
            TokenKind.Pipe => 7,      // Bitwise OR
            TokenKind.DotDot => 6,
            TokenKind.LessThan or TokenKind.GreaterThan or TokenKind.LessThanOrEqual
                or TokenKind.GreaterThanOrEqual => 5,
            TokenKind.EqualsEquals or TokenKind.NotEquals => 4,
            TokenKind.And => 3,       // Logical AND
            TokenKind.Or => 2,        // Logical OR
            TokenKind.QuestionQuestion => 1, // Lowest precedence, right-associative
            _ => 0
        };
    }

    /// <summary>
    /// Checks if an expression is a valid l-value (can appear on left side of assignment).
    /// </summary>
    /// <param name="expr">The expression to check.</param>
    /// <returns>True if the expression is a valid l-value, false otherwise.</returns>
    private static bool IsValidLValue(ExpressionNode expr)
    {
        return expr is IdentifierExpressionNode or MemberAccessExpressionNode or IndexExpressionNode or DereferenceExpressionNode;
    }

    /// <summary>
    /// Checks if a token kind can start a statement (used for detecting bare return).
    /// </summary>
    private static bool IsStatementStart(TokenKind kind)
    {
        return kind is TokenKind.Let or TokenKind.Const or TokenKind.Return
            or TokenKind.Break or TokenKind.Continue or TokenKind.Defer
            or TokenKind.For or TokenKind.If or TokenKind.Loop
            or TokenKind.OpenBrace;
    }

    /// <summary>
    /// Checks if the token after `return` indicates a bare return (no expression).
    /// Only tokens that cannot start an expression qualify. Note: if, for, loop,
    /// and { are expression starters, so `return if ...` / `return { ... }` are valid.
    /// </summary>
    private static bool IsBareReturn(TokenKind kind)
    {
        return kind is TokenKind.CloseBrace or TokenKind.EndOfFile
            or TokenKind.Let or TokenKind.Const or TokenKind.Return
            or TokenKind.Break or TokenKind.Continue or TokenKind.Defer;
    }

    /// <summary>
    /// Checks if a token kind is a delimiter that terminates a range expression.
    /// Used to detect partial ranges like x.. or ..y or ..
    /// </summary>
    private static bool IsRangeDelimiter(TokenKind kind)
    {
        return kind is TokenKind.CloseBracket or TokenKind.CloseParenthesis or TokenKind.Comma
            or TokenKind.CloseBrace or TokenKind.Semicolon or TokenKind.EndOfFile;
    }

    private sealed class ParserException(Diagnostic diagnostic) : Exception
    {
        public Diagnostic Diagnostic { get; } = diagnostic;
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
            TokenKind.And => BinaryOperatorKind.And,
            TokenKind.Or => BinaryOperatorKind.Or,
            TokenKind.Ampersand => BinaryOperatorKind.BitwiseAnd,
            TokenKind.Pipe => BinaryOperatorKind.BitwiseOr,
            TokenKind.Caret => BinaryOperatorKind.BitwiseXor,
            TokenKind.ShiftLeft => BinaryOperatorKind.ShiftLeft,
            TokenKind.ShiftRight => BinaryOperatorKind.ShiftRight,
            TokenKind.UnsignedShiftRight => BinaryOperatorKind.UnsignedShiftRight,
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

        // Parse condition: parens are optional, but body must be a block
        ExpressionNode condition;
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            // Parenthesized condition: if (expr) { ... }
            Eat(TokenKind.OpenParenthesis);
            condition = ParseExpression();
            Eat(TokenKind.CloseParenthesis);
        }
        else
        {
            // Bare condition: if expr { ... } — stop parsing at '{'
            _stopAtBrace = true;
            condition = ParseExpression();
            _stopAtBrace = false;
        }

        // Then branch must be a block
        var thenBranch = ParseBlockExpression();

        ExpressionNode? elseBranch = null;
        if (_currentToken.Kind == TokenKind.Else)
        {
            Eat(TokenKind.Else);
            // else if ... or else { ... }
            if (_currentToken.Kind == TokenKind.If)
                elseBranch = ParseIfExpression();
            else
                elseBranch = ParseBlockExpression();
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
            ExpressionNode fieldValue;
            if (_currentToken.Kind == TokenKind.Equals)
            {
                Eat(TokenKind.Equals);
                fieldValue = ParseExpression();
            }
            else if (_currentToken.Kind == TokenKind.Comma || _currentToken.Kind == TokenKind.CloseBrace)
            {
                // Shorthand: `field` is equivalent to `field = field`
                fieldValue = new IdentifierExpressionNode(fieldNameToken.Span, fieldNameToken.Text);
            }
            else
            {
                throw new ParserException(Diagnostic.Error(
                    "expected '=' in struct field",
                    _currentToken.Span,
                    "use `field = expr` or `field` shorthand",
                    "E1002"));
            }

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
            ExpressionNode fieldValue;
            if (_currentToken.Kind == TokenKind.Equals)
            {
                Eat(TokenKind.Equals);
                fieldValue = ParseExpression();
            }
            else if (_currentToken.Kind == TokenKind.Comma || _currentToken.Kind == TokenKind.CloseBrace)
            {
                // Shorthand: `field` is equivalent to `field = field`
                fieldValue = new IdentifierExpressionNode(fieldNameToken.Span, fieldNameToken.Text);
            }
            else
            {
                throw new ParserException(Diagnostic.Error(
                    "expected '=' in struct field",
                    _currentToken.Span,
                    "use `field = expr` or `field` shorthand",
                    "E1002"));
            }

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
                _currentToken.Kind != TokenKind.Loop &&
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

        Token iterator;
        ExpressionNode iterable;

        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            // Parenthesized: for (i in expr) { ... }
            Eat(TokenKind.OpenParenthesis);
            iterator = Eat(TokenKind.Identifier);
            Eat(TokenKind.In);
            iterable = ParseExpression();
            Eat(TokenKind.CloseParenthesis);
        }
        else
        {
            // Bare: for i in expr { ... }
            iterator = Eat(TokenKind.Identifier);
            Eat(TokenKind.In);
            _stopAtBrace = true;
            iterable = ParseExpression();
            _stopAtBrace = false;
        }

        // Body must be a block
        var body = ParseBlockExpression();

        var span = SourceSpan.Combine(forKeyword.Span, body.Span);
        return new ForLoopNode(span, iterator.Text, iterable, body);
    }

    /// <summary>
    /// Parses an infinite loop statement: loop { body }
    /// </summary>
    /// <returns>A <see cref="LoopNode"/> representing the loop.</returns>
    private LoopNode ParseLoop()
    {
        var loopKeyword = Eat(TokenKind.Loop);
        var body = ParseBlockExpression();
        return new LoopNode(loopKeyword.Span, body);
    }

    /// <summary>
    /// Parses a type expression with support for references, generics, and nullable types.
    /// Grammar:
    /// type := prefix_type postfix*
    /// prefix_type := '&' prefix_type | primary_type postfix*
    /// primary_type := identifier generic_args?
    /// generic_args := '[' type (',' type)* ']'
    /// postfix := '?' | '[]'
    ///
    /// Precedence (high to low): & > [] > ?
    /// This means: &u8? parses as (&u8)?, &u8[] parses as &(u8[])
    ///
    /// Examples:
    /// i32, &i32, i32?, &i32?, List[i32], &List[i32]?, Dict[String, i32]
    /// </summary>
    private TypeNode ParseType()
    {
        var startSpan = _currentToken.Span;

        // Parse prefix operators (reference: &) - binds tightest
        TypeNode type = ParsePrefixType();

        // Parse postfix ? (nullable) - binds loosest
        // This is separate from slice [] which binds tighter
        while (_currentToken.Kind == TokenKind.Question)
        {
            var questionToken = Eat(TokenKind.Question);
            var span = SourceSpan.Combine(startSpan, questionToken.Span);
            type = new NullableTypeNode(span, type);
        }

        return type;
    }

    /// <summary>
    /// Parses prefix types (reference) and slice postfix.
    /// Precedence: & > []
    /// </summary>
    private TypeNode ParsePrefixType()
    {
        var startSpan = _currentToken.Span;

        TypeNode type;
        if (_currentToken.Kind == TokenKind.Ampersand)
        {
            var ampToken = Eat(TokenKind.Ampersand);
            var innerType = ParsePrefixType(); // Recursively parse for nested references
            var span = SourceSpan.Combine(ampToken.Span, innerType.Span);
            type = new ReferenceTypeNode(span, innerType);
        }
        else
        {
            // Parse primary type (named type, array, or generic)
            type = ParsePrimaryType();
        }

        // Parse slice postfix [] - binds tighter than ?
        while (_currentToken.Kind == TokenKind.OpenBracket && PeekNextToken().Kind == TokenKind.CloseBracket)
        {
            // T[] - slice type (only if next token is immediately ']')
            var openBracket = Eat(TokenKind.OpenBracket);
            var closeBracket = Eat(TokenKind.CloseBracket);
            var span = SourceSpan.Combine(startSpan, closeBracket.Span);
            type = new SliceTypeNode(span, type);
        }

        return type;
    }

    /// <summary>
    /// Parses a primary type (identifier with optional generic arguments, or array type).
    /// Examples: i32, List[T], Dict[K, V], [i32; 5], $T, fn(i32, i32) i32, (T1, T2)
    /// </summary>
    private TypeNode ParsePrimaryType()
    {
        // Check for tuple type: (T1, T2) - desugars to anonymous struct { _0: T1, _1: T2 }
        // Note: (T) with single element and no trailing comma is NOT a tuple, just grouping
        // (T,) with trailing comma IS a tuple of one element
        if (_currentToken.Kind == TokenKind.OpenParenthesis)
        {
            return ParseTupleType();
        }

        // Check for function type: fn(T1, T2) R or fn(x: T1, y: T2) R
        if (_currentToken.Kind == TokenKind.Fn)
        {
            var fnKeyword = Eat(TokenKind.Fn);
            Eat(TokenKind.OpenParenthesis);

            var paramTypes = new List<TypeNode>();
            while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
            {
                // Support optional parameter names: fn(x: i32, y: i32) i32
                // The names are ignored but help document the type
                if (_currentToken.Kind == TokenKind.Identifier && PeekNextToken().Kind == TokenKind.Colon)
                {
                    Eat(TokenKind.Identifier); // consume name
                    Eat(TokenKind.Colon);      // consume colon
                }

                paramTypes.Add(ParseType());

                if (_currentToken.Kind == TokenKind.Comma)
                    Eat(TokenKind.Comma);
                else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                    break;
            }

            var closeParen = Eat(TokenKind.CloseParenthesis);

            // Parse return type (required for function types)
            var returnType = ParseType();

            var span = SourceSpan.Combine(fnKeyword.Span, returnType.Span);
            return new FunctionTypeNode(span, paramTypes, returnType);
        }

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

        // Anonymous struct type: struct { field: Type, ... }
        if (_currentToken.Kind == TokenKind.Struct)
        {
            return ParseAnonymousStructType();
        }

        // Anonymous enum type: enum { Variant, Variant(Type), ... }
        if (_currentToken.Kind == TokenKind.Enum)
        {
            return ParseAnonymousEnumType();
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
    /// Parses a tuple type: (T1, T2, ...) - desugars to anonymous struct { _0: T1, _1: T2, ... }
    /// Rules:
    /// - (T) = just T (grouping, not a tuple)
    /// - (T,) = { _0: T } (tuple of one with trailing comma)
    /// - (T1, T2) = { _0: T1, _1: T2 } (tuple of two or more)
    /// </summary>
    private TypeNode ParseTupleType()
    {
        var openParen = Eat(TokenKind.OpenParenthesis);

        // Handle empty tuple: () - desugars to { } (unit type)
        if (_currentToken.Kind == TokenKind.CloseParenthesis)
        {
            var closeParen = Eat(TokenKind.CloseParenthesis);
            var emptySpan = SourceSpan.Combine(openParen.Span, closeParen.Span);
            return new AnonymousStructTypeNode(emptySpan, new List<(string, TypeNode)>());
        }

        var types = new List<TypeNode>();
        bool hasTrailingComma = false;

        // Parse first type
        types.Add(ParseType());

        // Parse remaining types if there's a comma
        while (_currentToken.Kind == TokenKind.Comma)
        {
            Eat(TokenKind.Comma);

            // Check for trailing comma: (T,) or (T1, T2,)
            if (_currentToken.Kind == TokenKind.CloseParenthesis)
            {
                hasTrailingComma = true;
                break;
            }

            types.Add(ParseType());
        }

        var closeParenToken = Eat(TokenKind.CloseParenthesis);
        var span = SourceSpan.Combine(openParen.Span, closeParenToken.Span);

        // If single type with no trailing comma, it's just grouping (not a tuple)
        if (types.Count == 1 && !hasTrailingComma)
        {
            return types[0];
        }

        // Convert to anonymous struct with _0, _1, _2, ... field names
        var fields = new List<(string FieldName, TypeNode FieldType)>();
        for (int i = 0; i < types.Count; i++)
        {
            fields.Add(($"_{i}", types[i]));
        }

        return new AnonymousStructTypeNode(span, fields);
    }

    /// <summary>
    /// Parses an anonymous struct type expression: struct { field: Type, ... }
    /// </summary>
    private AnonymousStructTypeNode ParseAnonymousStructType()
    {
        var structKeyword = Eat(TokenKind.Struct);
        Eat(TokenKind.OpenBrace);

        var fields = new List<(string FieldName, TypeNode FieldType)>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var fieldNameToken = Eat(TokenKind.Identifier);
            Eat(TokenKind.Colon);
            var fieldType = ParseType();
            fields.Add((fieldNameToken.Text, fieldType));

            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = SourceSpan.Combine(structKeyword.Span, closeBrace.Span);
        return new AnonymousStructTypeNode(span, fields);
    }

    /// <summary>
    /// Parses an anonymous enum type expression: enum { Variant, Variant(Type), ... }
    /// </summary>
    private AnonymousEnumTypeNode ParseAnonymousEnumType()
    {
        var enumKeyword = Eat(TokenKind.Enum);
        Eat(TokenKind.OpenBrace);

        var variants = new List<(string Name, IReadOnlyList<TypeNode> PayloadTypes)>();
        while (_currentToken.Kind != TokenKind.CloseBrace && _currentToken.Kind != TokenKind.EndOfFile)
        {
            var variantNameToken = Eat(TokenKind.Identifier);

            var payloadTypes = new List<TypeNode>();
            if (_currentToken.Kind == TokenKind.OpenParenthesis)
            {
                Eat(TokenKind.OpenParenthesis);

                while (_currentToken.Kind != TokenKind.CloseParenthesis && _currentToken.Kind != TokenKind.EndOfFile)
                {
                    payloadTypes.Add(ParseType());

                    if (_currentToken.Kind == TokenKind.Comma)
                        Eat(TokenKind.Comma);
                    else if (_currentToken.Kind != TokenKind.CloseParenthesis) break;
                }

                Eat(TokenKind.CloseParenthesis);
            }

            variants.Add((variantNameToken.Text, payloadTypes));

            if (_currentToken.Kind == TokenKind.Comma) Eat(TokenKind.Comma);
        }

        var closeBrace = Eat(TokenKind.CloseBrace);
        var span = SourceSpan.Combine(enumKeyword.Span, closeBrace.Span);
        return new AnonymousEnumTypeNode(span, variants);
    }

    /// <summary>
    /// Parses a tuple expression or grouped expression: (a, b, ...) or (expr)
    /// Rules:
    /// - (expr) = just expr (grouping, not a tuple)
    /// - (expr,) = .{ _0 = expr } (tuple of one with trailing comma)
    /// - (a, b) = .{ _0 = a, _1 = b } (tuple of two or more)
    /// - () = .{ } (empty tuple / unit value)
    /// </summary>
    private ExpressionNode ParseTupleOrGroupedExpression()
    {
        var openParen = Eat(TokenKind.OpenParenthesis);

        // Handle empty tuple: () - desugars to .{ } (unit value)
        if (_currentToken.Kind == TokenKind.CloseParenthesis)
        {
            var closeParen = Eat(TokenKind.CloseParenthesis);
            var emptySpan = SourceSpan.Combine(openParen.Span, closeParen.Span);
            return new AnonymousStructExpressionNode(emptySpan, new List<(string, ExpressionNode)>());
        }

        var expressions = new List<ExpressionNode>();
        bool hasTrailingComma = false;

        // Parse first expression
        expressions.Add(ParseExpression());

        // Parse remaining expressions if there's a comma
        while (_currentToken.Kind == TokenKind.Comma)
        {
            Eat(TokenKind.Comma);

            // Check for trailing comma: (x,) or (a, b,)
            if (_currentToken.Kind == TokenKind.CloseParenthesis)
            {
                hasTrailingComma = true;
                break;
            }

            expressions.Add(ParseExpression());
        }

        var closeParenToken = Eat(TokenKind.CloseParenthesis);
        var span = SourceSpan.Combine(openParen.Span, closeParenToken.Span);

        // If single expression with no trailing comma, it's just grouping (not a tuple)
        if (expressions.Count == 1 && !hasTrailingComma)
        {
            return expressions[0];
        }

        // Convert to anonymous struct with _0, _1, _2, ... field names
        var fields = new List<(string FieldName, ExpressionNode Value)>();
        for (int i = 0; i < expressions.Count; i++)
        {
            fields.Add(($"_{i}", expressions[i]));
        }

        return new AnonymousStructExpressionNode(span, fields);
    }

    /// <summary>
    /// Parses a comma-separated list of call arguments, supporting named arguments (name = expr).
    /// Caller must have already consumed the opening parenthesis.
    /// </summary>
    private List<ExpressionNode> ParseCallArguments()
    {
        var arguments = new List<ExpressionNode>();
        while (_currentToken.Kind != TokenKind.CloseParenthesis &&
               _currentToken.Kind != TokenKind.EndOfFile)
        {
            // Check for named argument: identifier '=' (but not '==')
            if (_currentToken.Kind == TokenKind.Identifier && PeekNextToken().Kind == TokenKind.Equals)
            {
                var nameToken = Eat(TokenKind.Identifier);
                Eat(TokenKind.Equals);
                var value = ParseExpression();
                var span = SourceSpan.Combine(nameToken.Span, value.Span);
                arguments.Add(new NamedArgumentExpressionNode(span, nameToken.Span, nameToken.Text, value));
            }
            else
            {
                arguments.Add(ParseExpression());
            }

            if (_currentToken.Kind == TokenKind.Comma)
                Eat(TokenKind.Comma);
            else if (_currentToken.Kind != TokenKind.CloseParenthesis)
                break;
        }
        return arguments;
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
    private ArrayLiteralExpressionNode ParseArrayLiteral()
    {
        var openBracket = Eat(TokenKind.OpenBracket);

        // Empty array: []
        if (_currentToken.Kind == TokenKind.CloseBracket)
        {
            var closeBracket = Eat(TokenKind.CloseBracket);
            var span = SourceSpan.Combine(openBracket.Span, closeBracket.Span);
            return new ArrayLiteralExpressionNode(span, []);
        }

        // Parse first element
        var firstElement = ParseExpression();

        // Check if this is repeat syntax: [value; count]
        if (_currentToken.Kind == TokenKind.Semicolon)
        {
            Eat(TokenKind.Semicolon);

            var countExpr = ParseExpression();

            var closeBracket = Eat(TokenKind.CloseBracket);

            var span = SourceSpan.Combine(openBracket.Span, closeBracket.Span);
            return new ArrayLiteralExpressionNode(span, firstElement, countExpr);
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
    /// Tracks brace depth so entire bodies are skipped rather than stopping at keywords inside them.
    /// </summary>
    private void SynchronizeTopLevel()
    {
        int braceDepth = 0;
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            if (_currentToken.Kind == TokenKind.OpenBrace)
            {
                braceDepth++;
                _currentToken = _lexer.NextToken();
                continue;
            }

            if (_currentToken.Kind == TokenKind.CloseBrace)
            {
                if (braceDepth > 0)
                {
                    braceDepth--;
                    _currentToken = _lexer.NextToken();
                    continue;
                }
                // Stray } at top level — skip it
                _currentToken = _lexer.NextToken();
                continue;
            }

            if (braceDepth == 0 && IsTopLevelStart(_currentToken.Kind))
                return;

            _currentToken = _lexer.NextToken();
        }
    }

    private static bool IsTopLevelStart(TokenKind kind)
    {
        return kind is TokenKind.Pub or TokenKind.Struct or TokenKind.Enum
            or TokenKind.Fn or TokenKind.Test or TokenKind.Const
            or TokenKind.Import or TokenKind.Hash;
    }

    /// <summary>
    /// Synchronizes the parser to a statement boundary after encountering an error.
    /// Tracks brace depth so nested blocks are skipped entirely rather than stopping at inner braces.
    /// </summary>
    private void SynchronizeStatement()
    {
        int braceDepth = 0;
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            if (_currentToken.Kind == TokenKind.OpenBrace)
            {
                braceDepth++;
                _currentToken = _lexer.NextToken();
                continue;
            }

            if (_currentToken.Kind == TokenKind.CloseBrace)
            {
                if (braceDepth > 0)
                {
                    braceDepth--;
                    _currentToken = _lexer.NextToken();
                    continue;
                }
                // Depth 0: this } belongs to the caller (function body end) — stop without consuming
                return;
            }

            // Only consider recovery at depth 0 (back at the function body level)
            if (braceDepth == 0 && IsStatementStart(_currentToken.Kind))
                return;

            _currentToken = _lexer.NextToken();
        }
    }

    /// <summary>
    /// Synchronizes the parser to an expression boundary after encountering an error.
    /// Tracks (), [], {} depth so nested delimiters are skipped rather than treated as recovery points.
    /// </summary>
    private void SynchronizeExpression()
    {
        int depth = 0;
        while (_currentToken.Kind != TokenKind.EndOfFile)
        {
            switch (_currentToken.Kind)
            {
                case TokenKind.OpenParenthesis:
                case TokenKind.OpenBracket:
                case TokenKind.OpenBrace:
                    depth++;
                    _currentToken = _lexer.NextToken();
                    continue;

                case TokenKind.CloseParenthesis:
                case TokenKind.CloseBracket:
                case TokenKind.CloseBrace:
                    if (depth > 0)
                    {
                        depth--;
                        _currentToken = _lexer.NextToken();
                        continue;
                    }
                    // Closing delimiter for the caller — stop without consuming
                    return;
            }

            if (depth == 0)
            {
                if (_currentToken.Kind is TokenKind.Comma or TokenKind.Semicolon or TokenKind.FatArrow)
                    return;
                if (IsStatementStart(_currentToken.Kind))
                    return;
            }

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
                return new EnumVariantPatternNode(firstIdent.Span, null, firstIdent.Text, []);
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

    /// <summary>
    /// Parses an integer literal token text into its value and optional suffix.
    /// Supports decimal (123), hexadecimal (0xff), and underscore separators (1_000_000).
    /// </summary>
    /// <param name="text">The raw token text (e.g., "255u8", "0xffu8", "1_000i32").</param>
    /// <returns>A tuple of the parsed value and optional suffix.</returns>
    private static (BigInteger value, string? suffix) ParseIntegerLiteralValue(string text)
    {
        bool isHex = text.Length >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X');
        int digitStart = isHex ? 2 : 0;

        // Find where digits end and suffix begins
        int digitEnd = digitStart;
        if (isHex)
        {
            while (digitEnd < text.Length && (IsHexDigit(text[digitEnd]) || text[digitEnd] == '_'))
                digitEnd++;
        }
        else
        {
            while (digitEnd < text.Length && (char.IsDigit(text[digitEnd]) || text[digitEnd] == '_'))
                digitEnd++;
        }

        // Strip underscores for parsing
        var digitSpan = text[digitStart..digitEnd].Replace("_", "");
        var value = isHex
            // Prepend "0" to ensure BigInteger parses as unsigned (high bit set = negative otherwise)
            ? BigInteger.Parse("0" + digitSpan, System.Globalization.NumberStyles.HexNumber)
            : BigInteger.Parse(digitSpan);
        var suffix = digitEnd < text.Length ? text[digitEnd..] : null;

        return (value, suffix);
    }

    private static bool IsHexDigit(char c)
    {
        return char.IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
}
