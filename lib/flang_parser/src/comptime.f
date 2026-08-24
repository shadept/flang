// THE compile-time evaluator (RFC-021 §3): `#if` directive conditions
// (spec §7.7) and the template engine (`#if`, `#for`, `#(expr)`) both run
// through `ct_eval`. The environment is two layers: the closed context
// (`platform.os` / `platform.arch`, `runtime.testing` / `runtime.release`,
// `runtime.env["KEY"]` with Dict semantics - `String?`, unwrap with `??`)
// and, inside a template, the bindings (parameters, `#for` variables)
// layered on top. Template values are the `core.rtti` shapes (§5):
// `TypeInfo` / `FieldInfo` / `VariantInfo` / `ParamInfo` / `TypeKind`.
// Semantics mirror the reference compiler's CompileTimeEvaluator:
//
//   - E2116: unknown compile-time name or member (a typo is never
//     silently false)
//   - E2117: condition did not evaluate to a bool
//   - E2118: operand misuse (optional without `??`, non-bool logic
//     operands, disallowed expression forms)
//
// Also home to `flatten_module_decls`: decl-level `#if` resolves once,
// right after projection - only the active branch's declarations survive
// into collection.

import std.allocator
import std.conv
import std.dict
import std.env
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast

pub type ComptimeCtx = struct {
    os: String
    arch: String
    testing: bool
    release: bool
}

// The compiling host's context. os/arch resolve through this compiler's
// OWN #if - evaluated when the compiler binary itself was built.
pub fn host_ctx() ComptimeCtx {
    return .{
        os = host_os(),
        arch = host_arch(),
        testing = false,
        release = false,
    }
}

fn host_os() String {
    #if platform.os == "windows" {
        return "windows"
    }
    #if platform.os == "macos" {
        return "macos"
    }
    #if platform.os == "linux" {
        return "linux"
    }
    return "unknown"
}

fn host_arch() String {
    #if platform.arch == "arm64" {
        return "arm64"
    }
    #if platform.arch == "x86_64" {
        return "x86_64"
    }
    return "unknown"
}

// ─────────────────────────────────────────────────────────────────────────
// Values
// ─────────────────────────────────────────────────────────────────────────

// A compile-time value. `OptStr` is what `runtime.env[key]` yields -
// FLang Dict indexing returns an optional. The `Ns*` variants are the
// intermediate namespace steps of `platform.…` / `runtime.…` /
// `TypeKind.…` paths. Strings are views into the evaluator's arena (or
// the source text).
pub type CtValue = enum {
    B(bool)
    I(i64)
    S(String)
    Ident(String)
    OptStr(String?)
    List(List(CtValue))
    TypeInfo(CtTypeInfo)
    Field(CtField)
    Variant(CtVariant)
    Param(CtParam)
    Kind(i32)
    NsPlatform
    NsRuntime
    NsEnv
    NsTypeKind
}

// Template-time `core.rtti.TypeInfo`: `kind` is the `TypeKind` discriminant
// or -1 when the spelled type has none (`&T`, `T?`, an unknown name).
// Members are derived on access from `source`, so recursive types
// terminate. Layout (`size`/`align`/`offset`) is never available here.
pub type CtTypeInfo = struct {
    name: String
    kind: i32
    source: CtTypeSource
}

pub type CtTypeSource = enum {
    FromDecl(&TypeDecl)
    FromSyntax(&TypeExpr)
    NoSource
}

pub type CtField = struct {
    name: String
    type_expr: &TypeExpr
}

pub type CtVariant = struct {
    name: String
}

pub type CtParam = struct {
    name: String
    type_expr: &TypeExpr
}

pub const KIND_PRIMITIVE: i32 = 0
pub const KIND_ARRAY: i32 = 1
pub const KIND_STRUCT: i32 = 2
pub const KIND_ENUM: i32 = 3
pub const KIND_FUNCTION: i32 = 4

pub type CtError = struct {
    code: String
    message: OwnedString
    span: SourceSpan
}

pub type CtOutcome = enum {
    Active(bool)
    Invalid(CtError)
}

// Resolves a type name (as visible from the invoking module) to its
// declaration. The vtable shape: a context pointer plus a plain fn.
pub type CtLookup = struct {
    ctx: &u8
    resolve: fn(ctx: &u8, name: String) &TypeDecl?
}

fn no_lookup(ctx: &u8, name: String) &TypeDecl? {
    return null
}

// The evaluation environment: closed context + template bindings +
// nominal lookup + an arena for produced strings.
pub type CtEnv = struct {
    ctx: &ComptimeCtx
    bindings: Dict(String, CtValue)
    lookup: CtLookup
    alloc: &Allocator
}

pub fn ct_env(ctx: &ComptimeCtx, alloc: &Allocator, lookup: CtLookup) CtEnv {
    return .{
        ctx = ctx,
        bindings = dict(Some(alloc)),
        lookup = lookup,
        alloc = alloc,
    }
}

fn directive_env(ctx: &ComptimeCtx) CtEnv {
    let zero: usize = 0
    const lookup: CtLookup = .{ ctx = zero as &u8, resolve = no_lookup }
    return ct_env(ctx, or_global(null), lookup)
}

// Evaluates a #if condition to its branch decision, or the diagnostic
// to report. Never guesses: any invalid condition is `Invalid`.
pub fn eval_condition(ctx: &ComptimeCtx, cond: &Expr) CtOutcome {
    let env = directive_env(ctx)
    return ct_eval_condition(&env, cond) match {
        Ok(b) => CtOutcome.Active(b),
        Err(e) => CtOutcome.Invalid(e),
    }
}

// A condition must be a bool (E2117); an optional must be unwrapped (E2118).
pub fn ct_eval_condition(env: &CtEnv, cond: &Expr) Result(bool, CtError) {
    const v = ct_eval(env, cond)?
    return v match {
        B(b) => Ok(b),
        OptStr(_) => Err(CtError {
            code = "E2118",
            message = $"optional value must be unwrapped with `??` before use as a condition",
            span = expr_span(cond),
        }),
        _ => Err(CtError {
            code = "E2117",
            message = $"#if condition must be a bool, got {describe(&v)}",
            span = expr_span(cond),
        }),
    }
}

fn ct_err(code: String, message: OwnedString, span: SourceSpan) Result(CtValue, CtError) {
    return Err(CtError { code = code, message = message, span = span })
}

// ─────────────────────────────────────────────────────────────────────────
// Evaluation
// ─────────────────────────────────────────────────────────────────────────

pub fn ct_eval(env: &CtEnv, e: &Expr) Result(CtValue, CtError) {
    return e.* match {
        Lit(l) => l.value match {
            Bool(b) => Ok(CtValue.B(b.value)),
            String(s) => Ok(CtValue.S(s.text)),
            Int(i) => parse_i64(i.text.as_raw_bytes()) match {
                Ok(pair) => Ok(CtValue.I(pair.0)),
                Err(_) => ct_err("E2118", $"invalid integer literal `{i.text}`", i.span),
            },
            _ => ct_err("E2118", $"literal form not allowed at compile time", l.span),
        },
        Identifier(id) => {
            env.bindings[id.name] match {
                Some(v) => return Ok(v),
                None => {},
            }
            if id.name == "platform" { return Ok(CtValue.NsPlatform) }
            if id.name == "runtime" { return Ok(CtValue.NsRuntime) }
            if id.name == "TypeKind" { return Ok(CtValue.NsTypeKind) }
            ct_err("E2116", $"unknown compile-time name `{id.name}`", id.span)
        },
        MemberAccess(ma) => {
            const recv = ct_eval(env, ma.receiver)?
            ct_member(env, &recv, ma.member, ma.span)
        },
        Index(ix) => ct_index(env, &ix),
        Call(c) => ct_call(env, &c),
        Unary(u) => {
            const operand = ct_eval(env, u.operand)?
            u.op match {
                Not => operand match {
                    B(b) => Ok(CtValue.B(!b)),
                    _ => ct_err("E2118", $"`!` cannot be applied to {describe(&operand)}", u.span),
                },
                Neg => operand match {
                    I(i) => Ok(CtValue.I(-i)),
                    _ => ct_err("E2118", $"`-` cannot be applied to {describe(&operand)}", u.span),
                },
                _ => ct_err("E2118", $"operator not allowed at compile time", u.span),
            }
        },
        Coalesce(c) => {
            const lhs = ct_eval(env, c.lhs)?
            lhs match {
                OptStr(opt) => opt match {
                    Some(v) => Ok(CtValue.S(v)),
                    None => ct_eval(env, c.rhs),
                },
                _ => ct_err("E2118",
                    $"left operand of `??` must be an optional (a dict lookup), got {describe(&lhs)}", c.span),
            }
        },
        Binary(b) => ct_eval_binary(env, &b),
        _ => ct_err("E2118", $"expression form not allowed at compile time", expr_span(e)),
    }
}

fn ct_eval_binary(env: &CtEnv, b: &BinaryExpr) Result(CtValue, CtError) {
    const l = ct_eval(env, b.lhs)?
    const r = ct_eval(env, b.rhs)?

    if is_optional(&l) or is_optional(&r) {
        return ct_err("E2118", $"optional value must be unwrapped with `??` before use", b.span)
    }

    // bool × bool
    const lb = as_bool(&l)
    const rb = as_bool(&r)
    if lb.is_some() and rb.is_some() {
        const x = lb.unwrap()
        const y = rb.unwrap()
        b.op match {
            And => return Ok(CtValue.B(x and y)),
            Or => return Ok(CtValue.B(x or y)),
            Eq => return Ok(CtValue.B(x == y)),
            Ne => return Ok(CtValue.B(x != y)),
            _ => {},
        }
    }
    // int × int
    const li = as_int(&l)
    const ri = as_int(&r)
    if li.is_some() and ri.is_some() {
        const x = li.unwrap()
        const y = ri.unwrap()
        b.op match {
            Eq => return Ok(CtValue.B(x == y)),
            Ne => return Ok(CtValue.B(x != y)),
            Lt => return Ok(CtValue.B(x < y)),
            Gt => return Ok(CtValue.B(x > y)),
            Le => return Ok(CtValue.B(x <= y)),
            Ge => return Ok(CtValue.B(x >= y)),
            Add => return Ok(CtValue.I(x + y)),
            Sub => return Ok(CtValue.I(x - y)),
            Mul => return Ok(CtValue.I(x * y)),
            Div => {
                if y == 0 { return ct_err("E2118", $"division by zero", b.span) }
                return Ok(CtValue.I(x / y))
            },
            Mod => {
                if y == 0 { return ct_err("E2118", $"division by zero", b.span) }
                return Ok(CtValue.I(x % y))
            },
            _ => {},
        }
    }
    // string × string
    const ls = as_str(&l)
    const rs = as_str(&r)
    if ls.is_some() and rs.is_some() {
        const x = ls.unwrap()
        const y = rs.unwrap()
        b.op match {
            Eq => return Ok(CtValue.B(x == y)),
            Ne => return Ok(CtValue.B(x != y)),
            Add => {
                let sb = string_builder(x.len + y.len, Some(env.alloc))
                sb.append(x)
                sb.append(y)
                return Ok(CtValue.S(sb.as_view()))
            },
            _ => {},
        }
    }
    // TypeKind × TypeKind, Ident × Ident
    const lk = as_kind(&l)
    const rk = as_kind(&r)
    if lk.is_some() and rk.is_some() {
        b.op match {
            Eq => return Ok(CtValue.B(lk.unwrap() == rk.unwrap())),
            Ne => return Ok(CtValue.B(lk.unwrap() != rk.unwrap())),
            _ => {},
        }
    }
    const lid = as_ident(&l)
    const rid = as_ident(&r)
    if lid.is_some() and rid.is_some() {
        b.op match {
            Eq => return Ok(CtValue.B(lid.unwrap() == rid.unwrap())),
            Ne => return Ok(CtValue.B(lid.unwrap() != rid.unwrap())),
            _ => {},
        }
    }
    return ct_err("E2118",
        $"`{binary_op_text(b.op)}` cannot be applied to {describe(&l)} and {describe(&r)}", b.span)
}

fn binary_op_text(op: BinaryOp) String {
    return op match {
        Add => "+", Sub => "-", Mul => "*", Div => "/", Mod => "%",
        Eq => "==", Ne => "!=", Lt => "<", Gt => ">", Le => "<=", Ge => ">=",
        And => "and", Or => "or",
        _ => "?",
    }
}

fn ct_index(env: &CtEnv, ix: &IndexExpr) Result(CtValue, CtError) {
    const recv = ct_eval(env, ix.receiver)?
    // Slices: `list[a..b]`, `list[a..]`, `list[..b]`.
    ix.index.* match {
        Range(rg) => return ct_slice(env, &recv, &rg, ix.span),
        _ => {},
    }
    const key = ct_eval(env, ix.index)?
    return recv match {
        NsEnv => key match {
            S(k) => Ok(CtValue.OptStr(env(k))),
            _ => ct_err("E2118", $"runtime.env is indexed by a string key", ix.span),
        },
        List(items) => key match {
            I(i) => {
                if i < 0 or (i as usize) >= items.len {
                    return ct_err("E2118", $"index {i} out of range (len {items.len})", ix.span)
                }
                Ok(items[i as usize])
            },
            _ => ct_err("E2118", $"a list is indexed by an integer", ix.span),
        },
        _ => ct_err("E2118", $"cannot index {describe(&recv)}", ix.span),
    }
}

fn ct_slice(env: &CtEnv, recv: &CtValue, rg: &RangeExpr, span: SourceSpan) Result(CtValue, CtError) {
    const items: List(CtValue) = recv.* match {
        List(l) => l,
        _ => return ct_err("E2118", $"cannot slice {describe(recv)}", span),
    }
    let start: i64 = 0
    let end: i64 = items.len as i64
    rg.start match {
        Some(s) => start = ct_expect_int(env, s)?,
        None => {},
    }
    rg.end match {
        Some(e) => {
            end = ct_expect_int(env, e)?
            if rg.inclusive { end = end + 1 }
        },
        None => {},
    }
    if start < 0 or end > (items.len as i64) or start > end {
        return ct_err("E2118", $"slice {start}..{end} out of range (len {items.len})", span)
    }
    let out: List(CtValue) = list((end - start) as usize, Some(env.alloc))
    for i in (start as usize)..(end as usize) { out.push(items[i]) }
    return Ok(CtValue.List(out))
}

fn ct_expect_int(env: &CtEnv, e: &Expr) Result(i64, CtError) {
    const v = ct_eval(env, e)?
    return v match {
        I(i) => Ok(i),
        _ => Err(CtError { code = "E2118", message = $"expected an integer, got {describe(&v)}", span = expr_span(e) }),
    }
}

// Builtin functions: `type_of(T)` (identity), `type_named("Name")`,
// `lower`, `snake_case`, `pascal_case`.
fn ct_call(env: &CtEnv, c: &CallExpr) Result(CtValue, CtError) {
    const name: String = c.callee.* match {
        Identifier(id) => id.name,
        _ => return ct_err("E2118", $"only builtin functions can be called at compile time", c.span),
    }
    if c.args.len != 1 {
        return ct_err("E2118", $"`{name}` takes one argument", c.span)
    }
    const arg_expr: &Expr = c.args[0] match {
        Positional(e) => e,
        Named(_) => return ct_err("E2118", $"`{name}` takes a positional argument", c.span),
    }
    const arg = ct_eval(env, arg_expr)?
    const arg_span = expr_span(arg_expr)
    if name == "type_of" {
        return arg match {
            TypeInfo(_) => Ok(arg),
            _ => ct_err("E2118", $"`type_of` expects a type, got {describe(&arg)}", arg_span),
        }
    }
    if name == "type_named" {
        const tn: String = arg match {
            S(s) => s,
            _ => return ct_err("E2118", $"`type_named` expects a string, got {describe(&arg)}", arg_span),
        }
        env.lookup.resolve(env.lookup.ctx, tn) match {
            Some(td) => return Ok(CtValue.TypeInfo(type_info_of_decl(env, td))),
            None => return ct_err("E2003", $"Unknown type `{tn}`", c.span),
        }
    }
    const text: String = arg match {
        S(s) => s,
        Ident(i) => i,
        _ => return ct_err("E2118", $"`{name}` expects a string or identifier, got {describe(&arg)}", arg_span),
    }
    if name == "lower" { return Ok(CtValue.S(lower_case(env, text))) }
    if name == "snake_case" { return Ok(CtValue.S(snake_case(env, text))) }
    if name == "pascal_case" { return Ok(CtValue.S(pascal_case(env, text))) }
    return ct_err("E2116", $"unknown compile-time function `{name}`", c.span)
}

fn ct_member(env: &CtEnv, recv: &CtValue, member: String, span: SourceSpan) Result(CtValue, CtError) {
    return recv.* match {
        NsPlatform => {
            if member == "os" { return Ok(CtValue.S(env.ctx.os)) }
            if member == "arch" { return Ok(CtValue.S(env.ctx.arch)) }
            ct_err("E2116", $"unknown compile-time member `{member}`", span)
        },
        NsRuntime => {
            if member == "testing" { return Ok(CtValue.B(env.ctx.testing)) }
            if member == "release" { return Ok(CtValue.B(env.ctx.release)) }
            if member == "env" { return Ok(CtValue.NsEnv) }
            ct_err("E2116", $"unknown compile-time member `{member}`", span)
        },
        NsTypeKind => {
            if member == "Primitive" { return Ok(CtValue.Kind(KIND_PRIMITIVE)) }
            if member == "Array" { return Ok(CtValue.Kind(KIND_ARRAY)) }
            if member == "Struct" { return Ok(CtValue.Kind(KIND_STRUCT)) }
            if member == "Enum" { return Ok(CtValue.Kind(KIND_ENUM)) }
            if member == "Function" { return Ok(CtValue.Kind(KIND_FUNCTION)) }
            ct_err("E2116", $"unknown compile-time member `{member}`", span)
        },
        TypeInfo(t) => ct_type_member(env, &t, member, span),
        Field(f) => {
            if member == "name" { return Ok(CtValue.S(f.name)) }
            if member == "type_info" { return Ok(CtValue.TypeInfo(type_info_of(env, f.type_expr))) }
            if member == "offset" {
                return ct_err("E2120", $"`offset` is not available at template time (layout is computed after expansion)", span)
            }
            ct_err("E2116", $"cannot access member `{member}` on a field", span)
        },
        Variant(v) => {
            if member == "name" { return Ok(CtValue.S(v.name)) }
            ct_err("E2116", $"cannot access member `{member}` on a variant", span)
        },
        Param(p) => {
            if member == "name" { return Ok(CtValue.S(p.name)) }
            if member == "type_info" { return Ok(CtValue.TypeInfo(type_info_of(env, p.type_expr))) }
            ct_err("E2116", $"cannot access member `{member}` on a parameter", span)
        },
        Ident(i) => {
            if member == "text" { return Ok(CtValue.S(i)) }
            ct_err("E2116", $"cannot access member `{member}` on an identifier", span)
        },
        S(s) => {
            if member == "len" { return Ok(CtValue.I(s.len as i64)) }
            ct_err("E2116", $"cannot access member `{member}` on a string", span)
        },
        List(l) => {
            if member == "len" { return Ok(CtValue.I(l.len as i64)) }
            ct_err("E2116", $"cannot access member `{member}` on a list", span)
        },
        _ => ct_err("E2116", $"cannot access member `{member}` on {describe(recv)}", span),
    }
}

// `core.rtti.TypeInfo` members, derived from the declaration's syntax.
fn ct_type_member(env: &CtEnv, t: &CtTypeInfo, member: String, span: SourceSpan) Result(CtValue, CtError) {
    if member == "name" { return Ok(CtValue.S(t.name)) }
    if member == "kind" {
        if t.kind < 0 {
            return ct_err("E2118", $"`{t.name}` has no TypeKind at template time", span)
        }
        return Ok(CtValue.Kind(t.kind))
    }
    if member == "size" or member == "align" {
        return ct_err("E2120", $"`{member}` is not available at template time (layout is computed after expansion)", span)
    }
    if member == "type_params" or member == "type_args" {
        let empty: List(CtValue) = list(0, Some(env.alloc))
        return Ok(CtValue.List(empty))
    }
    if member == "fields" { return Ok(CtValue.List(type_fields(env, t))) }
    if member == "variants" { return Ok(CtValue.List(type_variants(env, t))) }
    if member == "params" { return Ok(CtValue.List(type_params(env, t))) }
    if member == "return_type" {
        const fn_te = type_function_syntax(t)
        fn_te match {
            Some(f) => f.return_type match {
                Some(rt) => return Ok(CtValue.TypeInfo(type_info_of(env, rt))),
                None => return Ok(CtValue.TypeInfo(void_type_info())),
            },
            None => return ct_err("E2118", $"`{t.name}` is not a function type", span),
        }
    }
    return ct_err("E2116", $"cannot access member `{member}` on a type", span)
}

// ─────────────────────────────────────────────────────────────────────────
// TypeInfo from declaration syntax
// ─────────────────────────────────────────────────────────────────────────

pub fn type_info_of_decl(env: &CtEnv, td: &TypeDecl) CtTypeInfo {
    return td.body match {
        AnonStruct(_) => CtTypeInfo { name = td.name, kind = KIND_STRUCT, source = CtTypeSource.FromDecl(td) },
        AnonEnum(_) => CtTypeInfo { name = td.name, kind = KIND_ENUM, source = CtTypeSource.FromDecl(td) },
        // `type X = Y` alias: the alias resolves to its target's shape.
        _ => type_info_of(env, &td.body),
    }
}

pub fn type_info_of(env: &CtEnv, te: &TypeExpr) CtTypeInfo {
    return te.* match {
        Named(n) => {
            if n.generic_args.len == 0 {
                env.lookup.resolve(env.lookup.ctx, n.name) match {
                    Some(td) => return type_info_of_decl(env, td),
                    None => {},
                }
                if is_primitive_name(n.name) {
                    return CtTypeInfo { name = n.name, kind = KIND_PRIMITIVE, source = CtTypeSource.NoSource }
                }
            }
            CtTypeInfo { name = spell_type(env, te), kind = -1, source = CtTypeSource.NoSource }
        },
        Function(_) => CtTypeInfo { name = spell_type(env, te), kind = KIND_FUNCTION, source = CtTypeSource.FromSyntax(te) },
        Array(_) => CtTypeInfo { name = spell_type(env, te), kind = KIND_ARRAY, source = CtTypeSource.NoSource },
        AnonStruct(_) => CtTypeInfo { name = spell_type(env, te), kind = KIND_STRUCT, source = CtTypeSource.FromSyntax(te) },
        AnonEnum(_) => CtTypeInfo { name = spell_type(env, te), kind = KIND_ENUM, source = CtTypeSource.FromSyntax(te) },
        _ => CtTypeInfo { name = spell_type(env, te), kind = -1, source = CtTypeSource.NoSource },
    }
}

fn void_type_info() CtTypeInfo {
    return CtTypeInfo { name = "void", kind = KIND_PRIMITIVE, source = CtTypeSource.NoSource }
}

fn type_syntax(t: &CtTypeInfo) &TypeExpr? {
    return t.source match {
        FromDecl(td) => Some(&td.body),
        FromSyntax(te) => Some(te),
        NoSource => null,
    }
}

fn type_function_syntax(t: &CtTypeInfo) FunctionType? {
    let found: FunctionType? = null
    const te = type_syntax(t)
    te match {
        Some(x) => x.* match {
            Function(f) => { found = Some(f) },
            _ => {},
        },
        None => {},
    }
    return found
}

fn type_fields(env: &CtEnv, t: &CtTypeInfo) List(CtValue) {
    let out: List(CtValue) = list(0, Some(env.alloc))
    const te = type_syntax(t)
    te match {
        Some(x) => x.* match {
            AnonStruct(st) => {
                for &f in st.fields {
                    out.push(CtValue.Field(CtField { name = f.name, type_expr = f.type_expr }))
                }
            },
            _ => {},
        },
        None => {},
    }
    return out
}

fn type_variants(env: &CtEnv, t: &CtTypeInfo) List(CtValue) {
    let out: List(CtValue) = list(0, Some(env.alloc))
    const te = type_syntax(t)
    te match {
        Some(x) => x.* match {
            AnonEnum(en) => {
                for &v in en.variants {
                    out.push(CtValue.Variant(CtVariant { name = v.name }))
                }
            },
            _ => {},
        },
        None => {},
    }
    return out
}

fn type_params(env: &CtEnv, t: &CtTypeInfo) List(CtValue) {
    let out: List(CtValue) = list(0, Some(env.alloc))
    const f = type_function_syntax(t)
    f match {
        Some(fnty) => {
            for i in 0..fnty.params.len {
                let pname: String = ""
                if i < fnty.param_names.len { pname = fnty.param_names[i] }
                if pname.len == 0 {
                    let sb = string_builder(4, Some(env.alloc))
                    sb.append('_')
                    sb.append(i as i64)
                    pname = sb.as_view()
                }
                out.push(CtValue.Param(CtParam { name = pname, type_expr = &fnty.params[i] }))
            }
        },
        None => {},
    }
    return out
}

pub fn is_primitive_name(name: String) bool {
    return name == "i8" or name == "i16" or name == "i32" or name == "i64"
        or name == "u8" or name == "u16" or name == "u32" or name == "u64"
        or name == "isize" or name == "usize" or name == "f32" or name == "f64"
        or name == "bool" or name == "char" or name == "void" or name == "never"
}

// The spelled type, re-parseable as a type expression.
pub fn spell_type(env: &CtEnv, te: &TypeExpr) String {
    let sb = string_builder(16, Some(env.alloc))
    spell_type_into(&sb, te)
    return sb.as_view()
}

pub fn spell_type_into(sb: &StringBuilder, te: &TypeExpr) {
    te.* match {
        Named(n) => {
            sb.append(n.name)
            if n.generic_args.len > 0 {
                sb.append('(')
                    let first = true
                for &g in n.generic_args {
                    if !first { sb.append(", ") }
                    first = false
                    spell_type_into(sb, g)
                }
                sb.append(')')
            }
        },
        GenericBind(g) => { sb.append('$'); sb.append(g.name) },
        Reference(r) => { sb.append('&'); spell_type_into(sb, r.inner) },
        Optional(o) => { spell_type_into(sb, o.inner); sb.append('?') },
        Array(a) => {
            sb.append('[')
            spell_type_into(sb, a.element)
            sb.append("; ")
            a.length.* match {
                Lit(l) => l.value match {
                    Int(i) => sb.append(i.text),
                    _ => sb.append('?'),
                },
                Identifier(id) => sb.append(id.name),
                _ => sb.append('?'),
            }
            sb.append(']')
        },
        Slice(s) => { spell_type_into(sb, s.element); sb.append("[]") },
        Tuple(t) => {
            sb.append('(')
            let first = true
            for &el in t.elements {
                if !first { sb.append(", ") }
                first = false
                spell_type_into(sb, el)
            }
            sb.append(')')
        },
        Function(f) => {
            sb.append("fn(")
            for i in 0..f.params.len {
                if i > 0 { sb.append(", ") }
                if i < f.param_names.len and f.param_names[i].len > 0 {
                    sb.append(f.param_names[i])
                    sb.append(": ")
                }
                spell_type_into(sb, &f.params[i])
            }
            sb.append(')')
            f.return_type match {
                Some(rt) => { sb.append(' '); spell_type_into(sb, rt) },
                None => {},
            }
        },
        AnonStruct(st) => {
            sb.append("struct { ")
            let first = true
            for &f in st.fields {
                if !first { sb.append(", ") }
                first = false
                sb.append(f.name)
                sb.append(": ")
                spell_type_into(sb, f.type_expr)
            }
            sb.append(" }")
        },
        AnonEnum(en) => {
            sb.append("enum { ")
            let first = true
            for &v in en.variants {
                if !first { sb.append(", ") }
                first = false
                sb.append(v.name)
            }
            sb.append(" }")
        },
        Error(_) => sb.append("<error>"),
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Stringify / helpers
// ─────────────────────────────────────────────────────────────────────────

// The text `#(expr)` pastes.
pub fn ct_stringify(v: &CtValue, sb: &StringBuilder) {
    v.* match {
        B(b) => sb.append(if b { "true" } else { "false" }),
        I(i) => sb.append(i),
        S(s) => sb.append(s),
        Ident(i) => sb.append(i),
        OptStr(o) => o match {
            Some(s) => sb.append(s),
            None => {},
        },
        TypeInfo(t) => sb.append(t.name),
        Field(f) => sb.append(f.name),
        Variant(va) => sb.append(va.name),
        Param(p) => sb.append(p.name),
        Kind(k) => sb.append(kind_name(k)),
        _ => {},
    }
}

fn kind_name(k: i32) String {
    if k == KIND_PRIMITIVE { return "Primitive" }
    if k == KIND_ARRAY { return "Array" }
    if k == KIND_STRUCT { return "Struct" }
    if k == KIND_ENUM { return "Enum" }
    if k == KIND_FUNCTION { return "Function" }
    return "?"
}

fn describe(v: &CtValue) String {
    return v.* match {
        B(_) => "a bool",
        I(_) => "an integer",
        S(_) => "a string",
        Ident(_) => "an identifier",
        OptStr(_) => "an optional",
        List(_) => "a list",
        TypeInfo(_) => "a type",
        Field(_) => "a field",
        Variant(_) => "a variant",
        Param(_) => "a parameter",
        Kind(_) => "a TypeKind",
        _ => "a compile-time namespace",
    }
}

fn is_optional(v: &CtValue) bool {
    return v.* match {
        OptStr(_) => true,
        _ => false,
    }
}

fn as_bool(v: &CtValue) bool? {
    return v.* match {
        B(b) => Some(b),
        _ => null,
    }
}

fn as_int(v: &CtValue) i64? {
    return v.* match {
        I(i) => Some(i),
        _ => null,
    }
}

fn as_str(v: &CtValue) String? {
    return v.* match {
        S(s) => Some(s),
        _ => null,
    }
}

fn as_ident(v: &CtValue) String? {
    return v.* match {
        Ident(s) => Some(s),
        _ => null,
    }
}

fn as_kind(v: &CtValue) i32? {
    return v.* match {
        Kind(k) => Some(k),
        _ => null,
    }
}

fn lower_case(env: &CtEnv, text: String) String {
    let sb = string_builder(text.len, Some(env.alloc))
    for c in text.as_raw_bytes() {
        sb.append_byte(if c >= 'A' as u8 and c <= 'Z' as u8 { c + 32 } else { c })
    }
    return sb.as_view()
}

fn snake_case(env: &CtEnv, text: String) String {
    let sb = string_builder(text.len + 4, Some(env.alloc))
    for c in text.as_raw_bytes() {
        if c >= 'A' as u8 and c <= 'Z' as u8 {
            if sb.len > 0 { sb.append_byte('_' as u8) }
            sb.append_byte(c + 32)
        } else {
            sb.append_byte(c)
        }
    }
    return sb.as_view()
}

fn pascal_case(env: &CtEnv, text: String) String {
    let sb = string_builder(text.len, Some(env.alloc))
    let capitalize = true
    for c in text.as_raw_bytes() {
        if c == '_' as u8 { capitalize = true; continue }
        sb.append_byte(if capitalize and c >= 'a' as u8 and c <= 'z' as u8 { c - 32 } else { c })
        capitalize = false
    }
    return sb.as_view()
}

// ─────────────────────────────────────────────────────────────────────────
// Decl-level flatten
// ─────────────────────────────────────────────────────────────────────────

// Resolves every decl-level #if in the module, immediately after
// projection: only the active branch's declarations survive into the
// module's decl list (nested #if resolves recursively). Invalid
// conditions produce diagnostics and drop both branches.
pub fn flatten_module_decls(m: &Module, ctx: &ComptimeCtx, diags: &List(Diagnostic), allocator: &Allocator? = null) {
    let flattened: List(Decl) = list(m.decls.len, allocator)
    splice_decls(&m.decls, ctx, diags, &flattened)
    m.set_decls(flattened)
}

fn splice_decls(decls: &List(Decl), ctx: &ComptimeCtx, diags: &List(Diagnostic), out: &List(Decl)) {
    for i in 0..decls.len {
        decls[i] match {
            IfDirective(ifd) => {
                eval_condition(ctx, &ifd.condition) match {
                    Active(active) => {
                        const branch: &List(Decl) = if active { &ifd.then_decls } else { &ifd.else_decls }
                        splice_decls(branch, ctx, diags, out)
                    },
                    Invalid(err) => {
                        let empty_hint: OwnedString
                        diags.push(Diagnostic {
                            severity = Severity.Error,
                            code = err.code,
                            message = err.message,
                            hint = empty_hint,
                            span = err.span,
                        })
                    },
                }
            },
            _ => { out.push(decls[i]) },
        }
    }
}
