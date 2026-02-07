using System.Text;

namespace FLang.Semantics.Test;

public static class Program
{
    public static void Main()
    {
        var program = new LetExpression("fac",
            new FunctionExpression("x",
                new ConditionalExpression(
                    BinOp(new VariableExpression("x"), "op_eq", new LiteralExpression(0)),
                    new LiteralExpression(1),
                    BinOp(new VariableExpression("x"), "mul",
                        Call("fac", BinOp(new VariableExpression("x"), "sub", new LiteralExpression(1)))
                    )
                )
            ),
            new VariableExpression("fac")
        );

        Console.WriteLine("Program:");
        Console.WriteLine(program);
        var checker = new TypeChecker();
        var type = checker.TypeOf(program);
        Console.WriteLine("Type:");
        Console.WriteLine(type);

        Console.WriteLine("_environment._types:");
        Console.WriteLine(checker._environment._types);
    }

    private static CallExpression Call(string fnName, Expression arg)
    {
        return new CallExpression(new VariableExpression(fnName), arg);
    }

    private static CallExpression BinOp(Expression left, string op, Expression right)
    {
        return new CallExpression(new CallExpression(new VariableExpression(op), left), right);
    }
}

public abstract record Expression
{
    public abstract override string ToString();
}

public sealed record LiteralExpression(object? Value) : Expression
{
    public override string ToString() => Value?.ToString() ?? "nulls";
}

public sealed record VariableExpression(string Name) : Expression
{
    public override string ToString() => Name;
}

public sealed record FunctionExpression(string Arg, Expression Body) : Expression
{
    public override string ToString() => $"\\{Arg} -> {Body}";
}

public sealed record CallExpression(Expression Function, Expression Argument) : Expression
{
    public override string ToString() => $"{Function} {Argument}";
}

public sealed record LetExpression(string Variable, Expression Value, Expression Body) : Expression
{
    public override string ToString() => $"let {Variable} = {Value} in {Body}";
}

public sealed record ConditionalExpression(Expression Condition, Expression Then, Expression Else) : Expression
{
    public override string ToString() => $"if {Condition} then {Then} else {Else}";
}



public abstract record Type
{
    public abstract override string ToString();
}

public sealed record LiteralType(System.Type Type) : Type
{
    public override string ToString() => $"Literal {Type}";

    public bool Equals(LiteralType? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        return base.Equals(other) && Type == other.Type;
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(base.GetHashCode(), Type);
    }
}

public sealed record VariableType(string Name) : Type
{
    public override string ToString() => Name;
}

public sealed record FunctionType(Type Arg, Type Result) : Type
{
    public override string ToString()
    {
        if (Arg is LiteralType or VariableType)
            return $"{Arg} -> {Result}";
        return $"({Arg}) -> {Result}";
    }
}

public sealed record PolymorphicType(HashSet<VariableType> BoundTypes, Type Type) : Type
{
    public override string ToString()
    {
        var bound = string.Join(", ", BoundTypes);
        return $"forall {bound} . {Type}";
    }

    public bool Equals(PolymorphicType? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        return base.Equals(other) && BoundTypes.SetEquals(other.BoundTypes) && Type.Equals(other.Type);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(base.GetHashCode(), BoundTypes, Type);
    }
}



public class TypeChecker
{
    private readonly Dictionary<string, Type> _typings = [];
    public readonly Environment _environment = new(); // Should be stack

    public TypeChecker()
    {
        _typings["op_eq"] = new PolymorphicType(
            [new VariableType("a")],
            new FunctionType(new VariableType("a"),
                new FunctionType(new VariableType("a"), new LiteralType(typeof(bool))))
        );
        var binOp = new FunctionType(new LiteralType(typeof(int)),
            new FunctionType(new LiteralType(typeof(int)), new LiteralType(typeof(int))));
        _typings["mul"] = new PolymorphicType([new VariableType("a")], binOp);
        _typings["sub"] = new PolymorphicType([new VariableType("a")], binOp);
    }

    public Type TypeOf(Expression expression)
    {
        return Environment.Generalize(W(expression));
    }

    public Type W(Expression expression)
    {
        return expression switch
        {
            LiteralExpression literal => W(literal),
            VariableExpression variable => W(variable),
            CallExpression call => W(call),
            FunctionExpression func => W(func),
            LetExpression let => W(let),
            ConditionalExpression cond => W(cond),
            _ => throw new Exception($"Unsupported expression type: {expression}")
        };
    }

    public static Type W(LiteralExpression literal)
    {
        var type = literal.Value?.GetType() ?? typeof(object);
        return new LiteralType(type);
    }

    public Type W(VariableExpression variable)
    {
        if (_typings.TryGetValue(variable.Name, out var type))
        {
            type = _environment.Specialize(type);
            type = _environment.Find(type);
            return type;
        }

        throw new Exception($"{variable.Name} is undefined");
    }

    public Type W(CallExpression call)
    {
        var function = W(call.Function);
        var arg = W(call.Argument);
        var result = _environment.NewVar();
        _environment.Unify(function, new FunctionType(arg, result));
        return _environment.Find(result);
    }

    public Type W(FunctionExpression function)
    {
        var arg = _environment.NewVar();
        _typings[function.Arg] = arg;
        var body = W(function.Body);
        return new FunctionType(_environment.Find(arg), body);
    }

    public Type W(LetExpression let)
    {
        var variable = _environment.NewVar();
        _typings[let.Variable] = variable;
        // Compute type of value and unify it with variable
        var value = W(let.Value);
        _environment.Unify(variable, value);
        // Generalize the type of var
        _typings[let.Variable] = Environment.Generalize(_environment.Find(variable));
        return W(let.Body);
    }

    public Type W(ConditionalExpression cond)
    {
        // forall a. bool -> a -> a -> a
        var condition = W(cond.Condition);
        _environment.Unify(condition, new LiteralType(typeof(bool)));

        var result = _environment.NewVar();
        var then = W(cond.Then);
        var @else = W(cond.Else);
        _environment.Unify(then, result);
        _environment.Unify(@else, result);
        return _environment.Find(result);
    }
}

public class Environment //(Dictionary<string, Type> typings)
{
    public readonly DisjointSet<Type> _types = new();
    private int _typevars = 0;

    public VariableType NewVar()
    {
        return new VariableType($"a{++_typevars}");
    }

    public Type Find(Type type)
    {
        return type switch
        {
            LiteralType literal => Find(literal),
            VariableType variable => Find(variable),
            FunctionType function => Find(function),
            _ => throw new ArgumentOutOfRangeException(nameof(type))
        };
    }

    private static LiteralType Find(LiteralType literal)
    {
        return literal;
    }

    private Type Find(VariableType variable)
    {
        var result = _types.Find(variable);
        return result == variable ? result : Find(result);
    }

    private FunctionType Find(FunctionType function)
    {
        return new FunctionType(Find(function.Arg), Find(function.Result));
    }


    public Type Specialize(Type type, Dictionary<Type, Type>? substitutions = null)
    {
        substitutions ??= [];
        return type switch
        {
            LiteralType l => Specialize(l, substitutions),
            VariableType v => Specialize(v, substitutions),
            FunctionType f => Specialize(f, substitutions),
            PolymorphicType p => Specialize(p, substitutions),
            _ => throw new NotImplementedException(),
        };
    }

    private static LiteralType Specialize(LiteralType literal, Dictionary<Type, Type> substitutions)
    {
        return literal;
    }

    private static Type Specialize(VariableType variable, Dictionary<Type, Type> substitutions)
    {
        return substitutions.GetValueOrDefault(variable, variable);
    }

    private FunctionType Specialize(FunctionType function, Dictionary<Type, Type> substitutions)
    {
        var arg = Specialize(function.Arg, substitutions);
        var result = Specialize(function.Result, substitutions);
        return new FunctionType(arg, result);
    }

    private Type Specialize(PolymorphicType polymorphic, Dictionary<Type, Type> substitutions)
    {
        foreach (var boundType in polymorphic.BoundTypes)
        {
            substitutions.Add(boundType, NewVar());
        }

        return Specialize(polymorphic.Type, substitutions);
    }

    /// <summary>
    /// Unifies two types.
    /// </summary>
    /// <param name="a">The first type.</param>
    /// <param name="b">The second type.</param>
    public void Unify(Type a, Type b)
    {
        a = Find(a);
        b = Find(b);
        if (a == b)
        {
            return;
        }

        if (a is FunctionType fa && b is FunctionType fb)
        {
            Unify(fa.Arg, fb.Arg);
            Unify(fa.Result, fb.Result);
        }
        else if (a is VariableType || b is VariableType)
        {
            // Ensure B is the variable
            if (a is VariableType)
            {
                (a, b) = (b, a);
            }

            if (FreeTypes(a).Contains(b))
            {
                throw new Exception($"Unification failed: {a} and {b} will result in a cyclic type");
            }

            _types.Merge(a, b);
        }
        else
        {
            throw new Exception($"{a} and {b} cannot be unified");
        }
    }

    public static Type Generalize(Type type)
    {
        var freeTypes = FreeTypes(type);
        if (freeTypes.Count == 0) return type;
        return new PolymorphicType(freeTypes, type);
    }

    private static HashSet<VariableType> FreeTypes(Type type)
    {
        var free = new HashSet<VariableType>();
        var stack = new Stack<Type>([type]);
        while (stack.TryPop(out var t))
        {
            switch (t)
            {
                case LiteralType l:
                    break;
                case VariableType v:
                    free.Add(v);
                    break;
                case FunctionType f:
                    stack.Push(f.Arg);
                    stack.Push(f.Result);
                    break;
                case PolymorphicType p:
                    throw new Exception("PolymorphicType cannot be generalized");
            }
        }

        return free;
    }
}

/// <summary>
/// Disjoint set data structure for union-find operations.
/// </summary>
public class DisjointSet<T> where T : notnull
{
    private readonly Dictionary<T, T> _parent = [];
    private readonly Dictionary<T, int> _size = [];

    public T Find(T item)
    {
        if (!_parent.TryGetValue(item, out T? parent))
        {
            _parent[item] = item;
            _size[item] = 1;
            return item;
        }

        var root = parent;
        while (!EqualityComparer<T>.Default.Equals(_parent[root], root))
        {
            _parent[root] = _parent[_parent[root]]; // path halving
            root = _parent[root];
        }

        _parent[item] = root;
        return root;
    }

    /// <summary>
    /// Merges the partitions of a and b. The representative of a's partition
    /// becomes the representative of the merged partition.
    /// </summary>
    public void Merge(T a, T b)
    {
        var rootA = Find(a);
        var rootB = Find(b);

        if (EqualityComparer<T>.Default.Equals(rootA, rootB))
            return;

        if (_size[rootA] < _size[rootB])
        {
            // rootB's tree is larger — it should be the structural parent.
            // Swap the identities: rootA takes rootB's parent/size and vice versa,
            // so rootA remains the representative while inheriting the bigger tree.
            (_parent[rootA], _parent[rootB]) = (_parent[rootB], _parent[rootA]);
            (_size[rootA], _size[rootB]) = (_size[rootB], _size[rootA]);
        }

        // rootA is now the larger (or equal) tree — parent rootB under it
        _parent[rootB] = rootA;
        _size[rootA] += _size[rootB];
    }

    public override string ToString()
    {
        var partitions = new Dictionary<T, List<T>>();
        foreach (var elem in _parent.Keys)
        {
            var root = Find(elem);
            if (!partitions.TryGetValue(root, out var list))
            {
                list = [];
                partitions[root] = list;
            }

            list.Add(elem);
        }

        var sb = new StringBuilder();
        sb.Append('{');
        var firstPartition = true;
        foreach (var kvp in partitions)
        {
            if (!firstPartition)
                sb.Append(", ");
            firstPartition = false;

            sb.Append(kvp.Key);
            sb.Append(": [");
            for (int i = 0; i < kvp.Value.Count; i++)
            {
                if (i > 0)
                    sb.Append(", ");
                sb.Append(kvp.Value[i]);
            }

            sb.Append(']');
        }

        sb.Append('}');
        return sb.ToString();
    }
}
