# C# `ref struct`: how it works

Reference notes on the C# feature itself. No FLang design decisions here.
Everything below is sourced; links at the bottom.

## The one-sentence version

A `ref struct` is a struct the compiler guarantees will only ever live on the
stack. The language spec puts it this way:

> The `ref` modifier indicates that the *non_record_struct_declaration* declares
> a type whose instances are allocated on the execution stack. These types are
> called ***ref struct*** types. The `ref` modifier declares that instances may
> contain ref-like fields, and shall not be copied out of its safe-context.
> (spec §16.2.3)

`Span<T>` and `ReadOnlySpan<T>` are the motivating examples. A `Span<T>` holds a
raw interior pointer into someone else's memory. If a `Span<T>` could be stored
in a field of a heap object, the pointer would outlive whatever it points at.
`ref struct` is the rule set that makes that impossible at compile time.

---

# Part 1: using it (the external view)

## Declaring

```csharp
public ref struct CustomRef
{
    public bool IsValid;
    public Span<int> Inputs;
    public Span<int> Outputs;
}
```

`readonly` goes before `ref`:

```csharp
public readonly ref struct ConversionRequest
{
    public double Rate { get; }
    public ReadOnlySpan<double> Values { get; }
}
```

## What you cannot do, and why

Every restriction below is a consequence of the same goal: a `ref struct` value
must never end up somewhere that outlives the current stack frame.

| Restriction | Why |
|---|---|
| Not usable as an array element type | Arrays live on the heap |
| Not usable as a field of a class, or of a non-`ref` struct | That struct might itself be on the heap, or be a field of a class |
| Cannot be boxed to `System.ValueType` or `System.Object` | Boxing copies the value onto the heap |
| Cannot be captured by a lambda or a local function | Captured variables are lifted into a compiler-generated class, which is heap allocated |
| Cannot appear in the same block as an `await` in an async method (before C# 13, not in async methods at all) | Locals live across an await get hoisted into a heap-allocated state machine |
| Cannot be in a code segment containing `yield return` (before C# 13, not in iterators at all) | Same reason: the iterator's locals become fields of a generated class |
| Cannot be converted to an interface it implements | That conversion is a boxing conversion |
| Cannot be a type argument, unless the type parameter says `allows ref struct` | The generic instantiation would otherwise have no way to know it must obey the stack-only rules |

The rules that say "before C# 13" got relaxed rather than removed. A `ref struct`
can now implement an interface, but it still cannot be converted to one, so the
methods are only reachable through a generic parameter constrained with
`allows ref struct`.

## `ref` fields

Inside a `ref struct` (and only there), a field can itself be a reference:

```csharp
public ref struct RefFieldExample
{
    private ref int number;
}
```

This is the feature that lets `Span<T>` be written in safe C#:

```csharp
public readonly ref struct Span<T>
{
    internal readonly ref T _reference;
    private readonly int _length;
    // Omitted for brevity...
}
```

A `ref` field can be null; `Unsafe.IsNullRef<T>` tests for it. The two `readonly`
positions mean different things, and they compose:

- `readonly ref`: you can only re-point the field (`= ref`) in a constructor or
  `init` accessor. You can assign through it (`=`) any time.
- `ref readonly`: you can re-point it any time. You can never assign through it.
- `readonly ref readonly`: both restrictions.

"The compiler ensures that a reference stored in a `ref` field doesn't outlive
its referent."

## `allows ref struct`

The generic escape hatch. It is called an *anti-constraint*: it widens what `T`
can be rather than narrowing it.

```csharp
class RefStructGeneric<T, S>
    where T : allows ref struct
    where S : T
{
}
```

Instances of such a `T` must obey ref safety: cannot be boxed, cannot be used
where a `ref struct` is not allowed (for example `static` fields), and can be
marked `scoped`.

Two gotchas worth knowing:

1. It is not inherited. In the example above, `S` cannot be a `ref struct`,
   because `S`'s own declaration has no `allows ref struct` clause.
2. A `T` that allows ref structs cannot be passed to a type parameter that does
   not:

```csharp
public class Allow<T> where T : allows ref struct { }
public class Disallow<T> { }

public class Example<T> where T : allows ref struct
{
    private Allow<T> fieldOne;     // OK
    private Disallow<T> fieldTwo;  // Error
}
```

## Cleanup

A `ref struct` cannot implement `IDisposable` in the ordinary way (the `using`
statement would need the interface conversion, which is a boxing conversion), so
C# matches `Dispose` structurally: any accessible, parameterless, `void`-returning
instance `Dispose` method makes the type usable with `using`. Since C# 13 a
`ref struct` can also implement `IDisposable`, but overload resolution still
prefers the structural match.

---

# Part 2: how it works (the internal view)

## In metadata

The compiler stamps the type with
`System.Runtime.CompilerServices.IsByRefLikeAttribute`. The API docs are blunt
about who it is for:

> This attribute is used by the compiler for tracking metadata. It should not be
> used by application developers.

That attribute is how a *consuming* assembly knows a type is byref-like without
having the source. The runtime also refuses to create heap instances of such
types, so the guarantee is not purely a C# convention.

## The two lifetimes

The compiler assigns every expression two scopes:

> - The *safe-context* defines the scope where any expression can be safely accessed.
> - The *ref-safe-context* defines the scope where a *reference* to any expression can be safely accessed or modified.

*safe-context* governs plain assignment (`=`). *ref-safe-context* governs ref
assignment (`= ref`), which re-points a reference at a different storage
location.

There are four values, from narrowest to widest:

1. **declaration-block**
2. **function-member**
3. **return-only**
4. **caller-context**

Two starting facts do most of the work:

- Any expression whose compile-time type is *not* a `ref struct` has a
  safe-context of **caller-context** (the widest). This is why the rules cost
  nothing for ordinary code.
- A `default` expression, of any type, is also caller-context.

## The single rule everything reduces to

> Given an assignment from an expression `E1` with a safe-context `S1`, to an
> expression `E2` with safe-context `S2`, it is an error if `S2` is a wider
> context than `S1`.

Read that as: you cannot put a short-lived thing into a long-lived slot. Three
corollaries the spec states directly:

- `return e1` requires `e1` to be at least **return-only**.
- `e1 = e2` requires `e2` to be at least as wide as `e1`.
- Assigning to an `out` parameter requires the right side to be at least
  **return-only**.

## Where each context comes from

**Parameters.** A `ref struct` parameter, including `this` on an instance method,
is **caller-context**. An `out` parameter of `ref struct` type is **return-only**.
`this` in a struct constructor is **return-only**.

**Locals.** A `ref struct` local takes the safe-context of its initializer. With
no initializer, it is caller-context. A `foreach` iteration variable takes the
safe-context of the loop's expression.

**Fields.** `e.F` has the same safe-context as `e`. Lifetime flows through field
access, it does not reset.

**Operators.** For `e1 + e2` or `c ? e1 : e2`, the result is the *narrowest*
safe-context among the operands. (The `bool` condition of `?:` is caller-context,
so it never narrows anything.)

**Method calls.** The result of `e1.M(e2, ...)` is the narrowest of the
contributing arguments, including the receiver. `scoped` parameters and `out`
arguments contribute nothing. This is the rule that makes
`span.Slice(0, 5)` inherit `span`'s lifetime instead of inventing a wider one.

## `scoped`

A one-word way to say "this does not escape":

> The `scoped` modifier restricts the *ref-safe-to-escape* or *safe-to-escape*
> lifetime [...] to the current method. By adding the `scoped` modifier, you
> assert that your code doesn't extend the lifetime of the variable.

Apply it to a parameter or a local. For `ref struct` types it works on both
parameters and locals; for everything else, only on reference variables (`ref`
locals, and `in`/`ref`/`out` parameters).

It is implicit in the three places where the wide default would be wrong:

> The `scoped` modifier is implicitly added to `this` in methods declared in a
> `struct`, `out` parameters, and `ref` parameters when the type is a `ref struct`.

Its practical effect is at the call site rather than inside the callee: a
`scoped` parameter contributes nothing to the safe-context of the return value,
so marking a parameter `scoped` lets the method return something long-lived even
when that argument was short-lived.

## Method arguments must match

The subtlest rule. When a call has `ref` arguments of `ref struct` type, the
compiler computes the narrowest safe-context across all the arguments, then
requires every `ref` argument of `ref struct` type to be assignable by a value of
that narrowest context. Without this, a call could smuggle a narrow value into a
wide `ref` slot by laundering it through a method body that looks locally fine.

---

## Reading list order for someone new

1. The `ref struct` reference page. Stop at the end of the restrictions list.
2. `Span<T>`'s source shape (the two-field version above). It makes the point of
   the whole feature obvious.
3. The safe-context section of the spec, but only §16.8.15 and §16.8.15.2 through
   §16.8.15.4. The invocation rules can wait until you hit an error you cannot
   explain.

## Sources

- [`ref` structure types (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/ref-struct) — restrictions, `ref` fields, `readonly` positions, disposable pattern, interface rules.
- [C# language specification, Structs](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/structs) — §16.2.3 `ref` modifier, §16.8.15 safe context constraint and its subsections.
- [Method parameters and modifiers (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/method-parameters) — safe-context and ref-safe-context definitions.
- [Declaration statements (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/declarations) — `scoped`, and where it is implicit.
- [Constraints on type parameters (C#)](https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/generics/constraints-on-type-parameters) — `allows ref struct`, inheritance and substitution gotchas.
- [`IsByRefLikeAttribute` (API reference)](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.compilerservices.isbyreflikeattribute) — the metadata marker.
- [The `ref` keyword (C# reference)](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/ref) — every context `ref` appears in.
