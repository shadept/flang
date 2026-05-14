// AST → JSON. Consumed by tools/cst_explorer_web's AST pane.
//
// Schema: `{ "kind": "Foo", "span": [start, length], ...fields }`.
// Optional fields are `null` when None. `&T` references are inlined.

import std.list
import std.option
import std.string
import std.string_builder
import flang_parser.ast
import flang_core.span

// ─────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────

pub fn ast_to_json(sb: &StringBuilder, module: &Module) {
    sb.append("{\"kind\":\"Module\",")
    emit_span(sb, module.span)
    sb.append(",\"decls\":[")
    for i in 0..module.decls.len {
        if i > 0 { sb.append(",") }
        emit_decl(sb, &module.decls[i])
    }
    sb.append("]}")
}

// ─────────────────────────────────────────────────────────────────────────
// Low-level helpers
// ─────────────────────────────────────────────────────────────────────────

fn emit_span(sb: &StringBuilder, span: SourceSpan) {
    sb.append("\"span\":[")
    sb.append(span.start)
    sb.append(",")
    sb.append(span.length)
    sb.append("]")
}

fn emit_string(sb: &StringBuilder, s: String) {
    sb.append_byte('"')
    for i in 0..s.len {
        const c = s[i]
        if c == '"' { sb.append("\\\"") }
        else if c == '\\' { sb.append("\\\\") }
        else if c == '\n' { sb.append("\\n") }
        else if c == '\r' { sb.append("\\r") }
        else if c == '\t' { sb.append("\\t") }
        else if c == 0x08 { sb.append("\\b") }
        else if c == 0x0C { sb.append("\\f") }
        else if c < 0x20 {
            sb.append("\\u00")
            sb.append_byte(json_hex_nibble(c >> 4))
            sb.append_byte(json_hex_nibble(c & 0x0F))
        }
        else { sb.append_byte(c) }
    }
    sb.append_byte('"')
}

fn json_hex_nibble(n: u8) u8 {
    if n < 10 { return '0' + n }
    return 'a' + (n - 10)
}

fn emit_bool(sb: &StringBuilder, b: bool) {
    if b { sb.append("true") } else { sb.append("false") }
}

fn emit_kv_string(sb: &StringBuilder, key: String, value: String) {
    sb.append(",\"")
    sb.append(key)
    sb.append("\":")
    emit_string(sb, value)
}

fn emit_kv_bool(sb: &StringBuilder, key: String, value: bool) {
    sb.append(",\"")
    sb.append(key)
    sb.append("\":")
    emit_bool(sb, value)
}

fn emit_kv_usize(sb: &StringBuilder, key: String, value: usize) {
    sb.append(",\"")
    sb.append(key)
    sb.append("\":")
    sb.append(value)
}

// ─────────────────────────────────────────────────────────────────────────
// Declarations
// ─────────────────────────────────────────────────────────────────────────

fn emit_decl(sb: &StringBuilder, decl: &Decl) {
    decl.* match {
        Import(imp) => emit_import_decl(sb, &imp),
        Function(fn_decl) => emit_function_decl(sb, &fn_decl),
        Type(td) => emit_type_decl(sb, &td),
        Const(c) => emit_const_decl(sb, &c),
        Test(t) => emit_test_decl(sb, &t),
        GenDef(g) => emit_gen_def(sb, &g),
        GenInvoke(g) => emit_gen_invoke(sb, &g),
        IfDirective(d) => emit_if_directive_decl(sb, &d),
        Error(e) => {
            sb.append("{\"kind\":\"Error\",")
            emit_span(sb, e.span)
            sb.append("}")
        }
    }
}

fn emit_import_decl(sb: &StringBuilder, imp: &ImportDecl) {
    sb.append("{\"kind\":\"Import\",")
    emit_span(sb, imp.span)
    emit_kv_bool(sb, "is_pub", imp.is_pub)
    sb.append(",\"path\":[")
    for i in 0..imp.path.len {
        if i > 0 { sb.append(",") }
        emit_string(sb, imp.path[i])
    }
    sb.append("]}")
}

fn emit_function_decl(sb: &StringBuilder, fn_decl: &FunctionDecl) {
    sb.append("{\"kind\":\"Function\",")
    emit_span(sb, fn_decl.span)
    emit_kv_bool(sb, "is_pub", fn_decl.is_pub)
    emit_kv_string(sb, "name", fn_decl.name)
    sb.append(",\"directives\":")
    emit_attributes(sb, &fn_decl.directives)
    sb.append(",\"params\":[")
    for i in 0..fn_decl.params.len {
        if i > 0 { sb.append(",") }
        emit_function_param(sb, &fn_decl.params[i])
    }
    sb.append("],\"return_type\":")
    fn_decl.return_type match {
        Some(rt) => emit_type_expr(sb, &rt),
        None => sb.append("null"),
    }
    sb.append(",\"body\":")
    fn_decl.body match {
        Some(body) => emit_block_expr(sb, &body),
        None => sb.append("null"),
    }
    sb.append("}")
}

fn emit_function_param(sb: &StringBuilder, p: &FunctionParam) {
    sb.append("{\"kind\":\"Param\",")
    emit_span(sb, p.span)
    emit_kv_string(sb, "name", p.name)
    emit_kv_bool(sb, "is_variadic", p.is_variadic)
    sb.append(",\"type\":")
    emit_type_expr(sb, &p.type_expr)
    sb.append(",\"default\":")
    p.default_value match {
        Some(dv) => emit_expr(sb, &dv),
        None => sb.append("null"),
    }
    sb.append("}")
}

fn emit_attributes(sb: &StringBuilder, attrs: &List(DeclAttribute)) {
    sb.append("[")
    for i in 0..attrs.len {
        if i > 0 { sb.append(",") }
        attrs[i] match {
            Foreign => sb.append("{\"kind\":\"Foreign\"}"),
            Inline => sb.append("{\"kind\":\"Inline\"}"),
            Intrinsic => sb.append("{\"kind\":\"Intrinsic\"}"),
            Simd => sb.append("{\"kind\":\"Simd\"}"),
            Deprecated(msg) => {
                sb.append("{\"kind\":\"Deprecated\",\"message\":")
                msg match {
                    Some(m) => emit_string(sb, m),
                    None => sb.append("null"),
                }
                sb.append("}")
            }
        }
    }
    sb.append("]")
}

fn emit_type_decl(sb: &StringBuilder, td: &TypeDecl) {
    sb.append("{\"kind\":\"TypeDecl\",")
    emit_span(sb, td.span)
    emit_kv_bool(sb, "is_pub", td.is_pub)
    emit_kv_string(sb, "name", td.name)
    sb.append(",\"directives\":")
    emit_attributes(sb, &td.directives)
    sb.append(",\"body\":")
    emit_type_expr(sb, &td.body)
    sb.append("}")
}

fn emit_const_decl(sb: &StringBuilder, c: &ConstDecl) {
    sb.append("{\"kind\":\"Const\",")
    emit_span(sb, c.span)
    emit_kv_bool(sb, "is_pub", c.is_pub)
    emit_kv_string(sb, "name", c.name)
    sb.append(",\"type\":")
    c.type_annotation match {
        Some(t) => emit_type_expr(sb, &t),
        None => sb.append("null"),
    }
    sb.append(",\"value\":")
    emit_expr(sb, &c.value)
    sb.append("}")
}

fn emit_test_decl(sb: &StringBuilder, t: &TestDecl) {
    sb.append("{\"kind\":\"Test\",")
    emit_span(sb, t.span)
    emit_kv_string(sb, "label", t.label)
    sb.append(",\"body\":")
    emit_block_expr(sb, &t.body)
    sb.append("}")
}

fn emit_gen_def(sb: &StringBuilder, g: &GenDef) {
    sb.append("{\"kind\":\"GenDef\",")
    emit_span(sb, g.span)
    emit_kv_string(sb, "name", g.name)
    emit_kv_usize(sb, "body_start", g.body_start)
    emit_kv_usize(sb, "body_end", g.body_end)
    sb.append(",\"params\":[")
    for i in 0..g.params.len {
        if i > 0 { sb.append(",") }
        sb.append("{\"kind\":\"GenParam\",")
        emit_span(sb, g.params[i].span)
        emit_kv_string(sb, "name", g.params[i].name)
        emit_kv_string(sb, "param_kind", g.params[i].kind)
        sb.append("}")
    }
    sb.append("]}")
}

fn emit_gen_invoke(sb: &StringBuilder, g: &GenInvoke) {
    sb.append("{\"kind\":\"GenInvoke\",")
    emit_span(sb, g.span)
    emit_kv_string(sb, "name", g.name)
    sb.append(",\"args\":[")
    for i in 0..g.args.len {
        if i > 0 { sb.append(",") }
        emit_expr(sb, &g.args[i])
    }
    sb.append("]}")
}

fn emit_if_directive_decl(sb: &StringBuilder, d: &IfDirectiveDecl) {
    sb.append("{\"kind\":\"IfDirective\",")
    emit_span(sb, d.span)
    sb.append(",\"condition\":")
    emit_expr(sb, &d.condition)
    sb.append(",\"then_decls\":[")
    for i in 0..d.then_decls.len {
        if i > 0 { sb.append(",") }
        emit_decl(sb, &d.then_decls[i])
    }
    sb.append("],\"else_decls\":[")
    for i in 0..d.else_decls.len {
        if i > 0 { sb.append(",") }
        emit_decl(sb, &d.else_decls[i])
    }
    sb.append("]}")
}

// ─────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────

fn emit_stmt(sb: &StringBuilder, s: &Stmt) {
    s.* match {
        Let(let_stmt) => emit_let_stmt(sb, &let_stmt),
        Expression(es) => {
            sb.append("{\"kind\":\"ExprStmt\",")
            emit_span(sb, es.span)
            sb.append(",\"expr\":")
            emit_expr(sb, &es.expr)
            sb.append("}")
        }
        Return(rs) => {
            sb.append("{\"kind\":\"Return\",")
            emit_span(sb, rs.span)
            sb.append(",\"value\":")
            rs.value match {
                Some(v) => emit_expr(sb, &v),
                None => sb.append("null"),
            }
            sb.append("}")
        }
        Defer(ds) => {
            sb.append("{\"kind\":\"Defer\",")
            emit_span(sb, ds.span)
            sb.append(",\"expr\":")
            emit_expr(sb, &ds.expr)
            sb.append("}")
        }
        Break(bs) => {
            sb.append("{\"kind\":\"Break\",")
            emit_span(sb, bs.span)
            sb.append("}")
        }
        Continue(cs) => {
            sb.append("{\"kind\":\"Continue\",")
            emit_span(sb, cs.span)
            sb.append("}")
        }
        For(fs) => emit_for_stmt(sb, &fs),
        While(ws) => emit_while_stmt(sb, &ws),
        Loop(ls) => emit_loop_stmt(sb, &ls),
        IfDirective(d) => {
            sb.append("{\"kind\":\"IfDirective\",")
            emit_span(sb, d.span)
            sb.append(",\"condition\":")
            emit_expr(sb, &d.condition)
            sb.append(",\"then_stmts\":[")
            for i in 0..d.then_stmts.len {
                if i > 0 { sb.append(",") }
                emit_stmt(sb, &d.then_stmts[i])
            }
            sb.append("],\"else_stmts\":[")
            for i in 0..d.else_stmts.len {
                if i > 0 { sb.append(",") }
                emit_stmt(sb, &d.else_stmts[i])
            }
            sb.append("]}")
        }
    }
}

fn emit_let_stmt(sb: &StringBuilder, ls: &LetStmt) {
    sb.append("{\"kind\":\"Let\",")
    emit_span(sb, ls.span)
    emit_kv_bool(sb, "is_const", ls.is_const)
    emit_kv_string(sb, "name", ls.name)
    sb.append(",\"type\":")
    ls.type_annotation match {
        Some(t) => emit_type_expr(sb, &t),
        None => sb.append("null"),
    }
    sb.append(",\"init\":")
    ls.init match {
        Some(init) => emit_expr(sb, &init),
        None => sb.append("null"),
    }
    sb.append("}")
}

fn emit_for_stmt(sb: &StringBuilder, fs: &ForStmt) {
    sb.append("{\"kind\":\"For\",")
    emit_span(sb, fs.span)
    emit_kv_string(sb, "var", fs.var_name)
    sb.append(",\"iter\":")
    emit_expr(sb, fs.iterable)
    sb.append(",\"body\":")
    emit_block_expr(sb, &fs.body)
    sb.append("}")
}

fn emit_while_stmt(sb: &StringBuilder, ws: &WhileStmt) {
    sb.append("{\"kind\":\"While\",")
    emit_span(sb, ws.span)
    sb.append(",\"cond\":")
    emit_expr(sb, ws.condition)
    sb.append(",\"body\":")
    emit_block_expr(sb, &ws.body)
    sb.append("}")
}

fn emit_loop_stmt(sb: &StringBuilder, ls: &LoopStmt) {
    sb.append("{\"kind\":\"Loop\",")
    emit_span(sb, ls.span)
    sb.append(",\"body\":")
    emit_block_expr(sb, &ls.body)
    sb.append("}")
}

// ─────────────────────────────────────────────────────────────────────────
// Expressions
// ─────────────────────────────────────────────────────────────────────────

fn emit_expr(sb: &StringBuilder, e: &Expr) {
    e.* match {
        Lit(lit) => emit_literal_expr(sb, &lit),
        InterpolatedString(is) => emit_interp_string(sb, &is),
        ArrayLit(al) => emit_array_lit(sb, &al),
        TupleLit(tl) => emit_tuple_lit(sb, &tl),
        StructLit(sl) => emit_struct_lit(sb, &sl),
        Identifier(id) => {
            sb.append("{\"kind\":\"Identifier\",")
            emit_span(sb, id.span)
            emit_kv_string(sb, "name", id.name)
            sb.append("}")
        }
        MemberAccess(ma) => {
            sb.append("{\"kind\":\"MemberAccess\",")
            emit_span(sb, ma.span)
            emit_kv_string(sb, "member", ma.member)
            sb.append(",\"receiver\":")
            emit_expr(sb, ma.receiver)
            sb.append("}")
        }
        AddressOf(ao) => {
            sb.append("{\"kind\":\"AddressOf\",")
            emit_span(sb, ao.span)
            sb.append(",\"operand\":")
            emit_expr(sb, ao.operand)
            sb.append("}")
        }
        Dereference(d) => {
            sb.append("{\"kind\":\"Dereference\",")
            emit_span(sb, d.span)
            sb.append(",\"operand\":")
            emit_expr(sb, d.operand)
            sb.append("}")
        }
        NullPropagation(np) => {
            sb.append("{\"kind\":\"NullPropagation\",")
            emit_span(sb, np.span)
            emit_kv_string(sb, "member", np.member)
            sb.append(",\"receiver\":")
            emit_expr(sb, np.receiver)
            sb.append("}")
        }
        Index(ix) => {
            sb.append("{\"kind\":\"Index\",")
            emit_span(sb, ix.span)
            sb.append(",\"receiver\":")
            emit_expr(sb, ix.receiver)
            sb.append(",\"index\":")
            emit_expr(sb, ix.index)
            sb.append("}")
        }
        Call(c) => emit_call_expr(sb, &c),
        Cast(cx) => {
            sb.append("{\"kind\":\"Cast\",")
            emit_span(sb, cx.span)
            sb.append(",\"operand\":")
            emit_expr(sb, cx.operand)
            sb.append(",\"target\":")
            emit_type_expr(sb, cx.target)
            sb.append("}")
        }
        Binary(b) => {
            sb.append("{\"kind\":\"Binary\",")
            emit_span(sb, b.span)
            emit_kv_string(sb, "op", json_binary_op_str(b.op))
            sb.append(",\"lhs\":")
            emit_expr(sb, b.lhs)
            sb.append(",\"rhs\":")
            emit_expr(sb, b.rhs)
            sb.append("}")
        }
        Unary(u) => {
            sb.append("{\"kind\":\"Unary\",")
            emit_span(sb, u.span)
            emit_kv_string(sb, "op", json_unary_op_str(u.op))
            sb.append(",\"operand\":")
            emit_expr(sb, u.operand)
            sb.append("}")
        }
        Range(r) => {
            sb.append("{\"kind\":\"Range\",")
            emit_span(sb, r.span)
            emit_kv_bool(sb, "inclusive", r.inclusive)
            sb.append(",\"start\":")
            r.start match {
                Some(s) => emit_expr(sb, s),
                None => sb.append("null"),
            }
            sb.append(",\"end\":")
            r.end match {
                Some(e2) => emit_expr(sb, e2),
                None => sb.append("null"),
            }
            sb.append("}")
        }
        Coalesce(c) => {
            sb.append("{\"kind\":\"Coalesce\",")
            emit_span(sb, c.span)
            sb.append(",\"lhs\":")
            emit_expr(sb, c.lhs)
            sb.append(",\"rhs\":")
            emit_expr(sb, c.rhs)
            sb.append("}")
        }
        Try(t) => {
            sb.append("{\"kind\":\"Try\",")
            emit_span(sb, t.span)
            sb.append(",\"operand\":")
            emit_expr(sb, t.operand)
            sb.append("}")
        }
        Assignment(a) => {
            sb.append("{\"kind\":\"Assignment\",")
            emit_span(sb, a.span)
            sb.append(",\"lhs\":")
            emit_expr(sb, a.lhs)
            sb.append(",\"rhs\":")
            emit_expr(sb, a.rhs)
            sb.append("}")
        }
        Block(b) => emit_block_expr(sb, &b),
        If(ie) => emit_if_expr(sb, &ie),
        Match(m) => emit_match_expr(sb, &m),
        Lambda(l) => emit_lambda_expr(sb, &l),
        Error(e) => {
            sb.append("{\"kind\":\"Error\",")
            emit_span(sb, e.span)
            sb.append("}")
        }
    }
}

fn emit_literal_expr(sb: &StringBuilder, lit: &LiteralExpr) {
    sb.append("{\"kind\":\"Lit\",")
    emit_span(sb, lit.span)
    emit_literal_payload(sb, lit.value)
    sb.append("}")
}

// Inline the LiteralValue as scalars on the parent. The inner value
// has no own span (same range as the enclosing literal); nesting it
// gave consumers a `[0..0]` phantom child that trapped source-click.
fn emit_literal_payload(sb: &StringBuilder, v: LiteralValue) {
    v match {
        Int(i) => {
            sb.append(",\"literal\":\"Int\",\"text\":")
            emit_string(sb, i.text)
            sb.append(",\"suffix\":")
            emit_string(sb, i.suffix)
        }
        Float(f) => {
            sb.append(",\"literal\":\"Float\",\"text\":")
            emit_string(sb, f.text)
            sb.append(",\"suffix\":")
            emit_string(sb, f.suffix)
        }
        String(s) => {
            sb.append(",\"literal\":\"String\",\"text\":")
            emit_string(sb, s.text)
        }
        Char(c) => {
            sb.append(",\"literal\":\"Char\",\"text\":")
            emit_string(sb, c.text)
        }
        Byte(b) => {
            sb.append(",\"literal\":\"Byte\",\"text\":")
            emit_string(sb, b.text)
        }
        Bool(b) => {
            sb.append(",\"literal\":\"Bool\",\"bool_value\":")
            emit_bool(sb, b.value)
        }
        Null => sb.append(",\"literal\":\"Null\""),
    }
}

fn emit_interp_string(sb: &StringBuilder, is: &InterpolatedStringExpr) {
    sb.append("{\"kind\":\"InterpolatedString\",")
    emit_span(sb, is.span)
    sb.append(",\"target\":")
    is.target match {
        InterpolationTarget.NewString(args) => {
            sb.append("{\"kind\":\"NewString\",\"args\":[")
            for i in 0..args.len {
                if i > 0 { sb.append(",") }
                emit_expr(sb, &args[i])
            }
            sb.append("]}")
        }
        InterpolationTarget.IntoBuilder(b) => {
            sb.append("{\"kind\":\"IntoBuilder\",\"builder\":")
            emit_expr(sb, b)
            sb.append("}")
        }
    }
    sb.append(",\"parts\":[")
    for i in 0..is.parts.len {
        if i > 0 { sb.append(",") }
        is.parts[i] match {
            InterpolationPart.Text(t) => {
                sb.append("{\"kind\":\"Text\",\"text\":")
                emit_string(sb, t)
                sb.append("}")
            }
            InterpolationPart.Hole(h) => {
                sb.append("{\"kind\":\"Hole\",")
                emit_span(sb, h.span)
                sb.append(",\"expr\":")
                emit_expr(sb, h.expr)
                sb.append(",\"format\":")
                h.format match {
                    Some(f) => emit_string(sb, f),
                    None => sb.append("null"),
                }
                sb.append("}")
            }
        }
    }
    sb.append("]}")
}

fn emit_array_lit(sb: &StringBuilder, al: &ArrayLiteralExpr) {
    sb.append("{\"kind\":\"ArrayLit\",")
    emit_span(sb, al.span)
    sb.append(",\"shape\":")
    al.kind match {
        Elements(es) => {
            sb.append("{\"kind\":\"Elements\",\"elements\":[")
            for i in 0..es.len {
                if i > 0 { sb.append(",") }
                emit_expr(sb, &es[i])
            }
            sb.append("]}")
        }
        Repeat(r) => {
            sb.append("{\"kind\":\"Repeat\",\"value\":")
            emit_expr(sb, r.value)
            sb.append(",\"count\":")
            emit_expr(sb, r.count)
            sb.append("}")
        }
    }
    sb.append("}")
}

fn emit_tuple_lit(sb: &StringBuilder, tl: &TupleLiteralExpr) {
    sb.append("{\"kind\":\"TupleLit\",")
    emit_span(sb, tl.span)
    sb.append(",\"elements\":[")
    for i in 0..tl.elements.len {
        if i > 0 { sb.append(",") }
        emit_expr(sb, &tl.elements[i])
    }
    sb.append("]}")
}

fn emit_struct_lit(sb: &StringBuilder, sl: &StructLiteralExpr) {
    sb.append("{\"kind\":\"StructLit\",")
    emit_span(sb, sl.span)
    sb.append(",\"type\":")
    sl.type_expr match {
        Some(te) => emit_type_expr(sb, te),
        None => sb.append("null"),
    }
    sb.append(",\"fields\":[")
    for i in 0..sl.fields.len {
        if i > 0 { sb.append(",") }
        sb.append("{\"kind\":\"Field\",")
        emit_span(sb, sl.fields[i].span)
        emit_kv_string(sb, "name", sl.fields[i].name)
        sb.append(",\"value\":")
        sl.fields[i].value match {
            Some(v) => emit_expr(sb, v),
            None => sb.append("null"),
        }
        sb.append("}")
    }
    sb.append("]}")
}

fn emit_call_expr(sb: &StringBuilder, c: &CallExpr) {
    sb.append("{\"kind\":\"Call\",")
    emit_span(sb, c.span)
    sb.append(",\"callee\":")
    emit_expr(sb, c.callee)
    sb.append(",\"args\":[")
    for i in 0..c.args.len {
        if i > 0 { sb.append(",") }
        c.args[i] match {
            // No `Positional` wrapper: it would have no own span and trap
            // source-click descent. Named args still wrap (they carry a name).
            Positional(e) => emit_expr(sb, e),
            Named(n) => {
                sb.append("{\"kind\":\"Named\",")
                emit_span(sb, n.span)
                emit_kv_string(sb, "name", n.name)
                sb.append(",\"value\":")
                emit_expr(sb, n.value)
                sb.append("}")
            }
        }
    }
    sb.append("]}")
}

fn emit_block_expr(sb: &StringBuilder, b: &BlockExpr) {
    sb.append("{\"kind\":\"Block\",")
    emit_span(sb, b.span)
    sb.append(",\"stmts\":[")
    for i in 0..b.stmts.len {
        if i > 0 { sb.append(",") }
        emit_stmt(sb, &b.stmts[i])
    }
    sb.append("],\"trailing\":")
    b.trailing match {
        Some(t) => emit_expr(sb, t),
        None => sb.append("null"),
    }
    sb.append("}")
}

fn emit_if_expr(sb: &StringBuilder, ie: &IfExpr) {
    sb.append("{\"kind\":\"If\",")
    emit_span(sb, ie.span)
    sb.append(",\"cond\":")
    emit_expr(sb, ie.condition)
    sb.append(",\"then\":")
    emit_block_expr(sb, &ie.then_branch)
    sb.append(",\"else\":")
    ie.else_branch match {
        ElseBranch.NoElse => sb.append("null"),
        ElseBranch.Block(blk) => emit_block_expr(sb, &blk),
        ElseBranch.If(nested) => emit_if_expr(sb, nested),
    }
    sb.append("}")
}

fn emit_match_expr(sb: &StringBuilder, m: &MatchExpr) {
    sb.append("{\"kind\":\"Match\",")
    emit_span(sb, m.span)
    sb.append(",\"scrutinee\":")
    emit_expr(sb, m.scrutinee)
    sb.append(",\"arms\":[")
    for i in 0..m.arms.len {
        if i > 0 { sb.append(",") }
        sb.append("{\"kind\":\"Arm\",")
        emit_span(sb, m.arms[i].span)
        sb.append(",\"pattern\":")
        emit_pattern(sb, &m.arms[i].pattern)
        sb.append(",\"guard\":")
        m.arms[i].guard match {
            Some(g) => emit_expr(sb, g),
            None => sb.append("null"),
        }
        sb.append(",\"body\":")
        emit_expr(sb, m.arms[i].body)
        sb.append("}")
    }
    sb.append("]}")
}

fn emit_lambda_expr(sb: &StringBuilder, l: &LambdaExpr) {
    sb.append("{\"kind\":\"Lambda\",")
    emit_span(sb, l.span)
    sb.append(",\"params\":[")
    for i in 0..l.params.len {
        if i > 0 { sb.append(",") }
        emit_function_param(sb, &l.params[i])
    }
    sb.append("],\"return_type\":")
    l.return_type match {
        Some(rt) => emit_type_expr(sb, &rt),
        None => sb.append("null"),
    }
    sb.append(",\"body\":")
    emit_block_expr(sb, &l.body)
    sb.append("}")
}

fn json_binary_op_str(op: BinaryOp) String {
    return op match {
        Add => "+",
        Sub => "-",
        Mul => "*",
        Div => "/",
        Mod => "%",
        Eq => "==",
        Ne => "!=",
        Lt => "<",
        Gt => ">",
        Le => "<=",
        Ge => ">=",
        And => "and",
        Or => "or",
        BitAnd => "&",
        BitOr => "|",
        BitXor => "^",
        Shl => "<<",
        Shr => ">>",
        UShr => ">>>",
    }
}

fn json_unary_op_str(op: UnaryOp) String {
    return op match {
        Neg => "-",
        Not => "!",
        BitNot => "~",
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Type expressions
// ─────────────────────────────────────────────────────────────────────────

fn emit_type_expr(sb: &StringBuilder, t: &TypeExpr) {
    const t_val = t.*
    t_val match {
        Named(n) => {
            sb.append("{\"kind\":\"Named\",")
            emit_span(sb, n.span)
            emit_kv_string(sb, "name", n.name)
            sb.append(",\"generic_args\":[")
            for i in 0..n.generic_args.len {
                if i > 0 { sb.append(",") }
                emit_type_expr(sb, &n.generic_args[i])
            }
            sb.append("]}")
        }
        GenericBind(g) => {
            sb.append("{\"kind\":\"GenericBind\",")
            emit_span(sb, g.span)
            emit_kv_string(sb, "name", g.name)
            sb.append("}")
        }
        Reference(r) => {
            sb.append("{\"kind\":\"Reference\",")
            emit_span(sb, r.span)
            sb.append(",\"inner\":")
            emit_type_expr(sb, r.inner)
            sb.append("}")
        }
        Optional(o) => {
            sb.append("{\"kind\":\"Optional\",")
            emit_span(sb, o.span)
            sb.append(",\"inner\":")
            emit_type_expr(sb, o.inner)
            sb.append("}")
        }
        Array(a) => {
            sb.append("{\"kind\":\"Array\",")
            emit_span(sb, a.span)
            sb.append(",\"element\":")
            emit_type_expr(sb, a.element)
            sb.append(",\"length\":")
            emit_expr(sb, a.length)
            sb.append("}")
        }
        Slice(s) => {
            sb.append("{\"kind\":\"Slice\",")
            emit_span(sb, s.span)
            sb.append(",\"element\":")
            emit_type_expr(sb, s.element)
            sb.append("}")
        }
        Tuple(tup) => {
            sb.append("{\"kind\":\"Tuple\",")
            emit_span(sb, tup.span)
            sb.append(",\"elements\":[")
            for i in 0..tup.elements.len {
                if i > 0 { sb.append(",") }
                emit_type_expr(sb, &tup.elements[i])
            }
            sb.append("]}")
        }
        Function(f) => {
            sb.append("{\"kind\":\"FunctionType\",")
            emit_span(sb, f.span)
            sb.append(",\"params\":[")
            for i in 0..f.params.len {
                if i > 0 { sb.append(",") }
                emit_type_expr(sb, &f.params[i])
            }
            sb.append("],\"return_type\":")
            f.return_type match {
                Some(rt) => emit_type_expr(sb, rt),
                None => sb.append("null"),
            }
            sb.append("}")
        }
        AnonStruct(s) => {
            sb.append("{\"kind\":\"AnonStruct\",")
            emit_span(sb, s.span)
            sb.append(",\"generics\":[")
            for i in 0..s.generics.len {
                if i > 0 { sb.append(",") }
                sb.append("{\"name\":")
                emit_string(sb, s.generics[i].name)
                sb.append("}")
            }
            sb.append("],\"fields\":[")
            for i in 0..s.fields.len {
                if i > 0 { sb.append(",") }
                sb.append("{\"kind\":\"Field\",")
                emit_span(sb, s.fields[i].span)
                emit_kv_string(sb, "name", s.fields[i].name)
                sb.append(",\"type\":")
                emit_type_expr(sb, s.fields[i].type_expr)
                sb.append("}")
            }
            sb.append("]}")
        }
        AnonEnum(e) => {
            sb.append("{\"kind\":\"AnonEnum\",")
            emit_span(sb, e.span)
            sb.append(",\"generics\":[")
            for i in 0..e.generics.len {
                if i > 0 { sb.append(",") }
                sb.append("{\"name\":")
                emit_string(sb, e.generics[i].name)
                sb.append("}")
            }
            sb.append("],\"variants\":[")
            for i in 0..e.variants.len {
                if i > 0 { sb.append(",") }
                sb.append("{\"kind\":\"Variant\",")
                emit_span(sb, e.variants[i].span)
                emit_kv_string(sb, "name", e.variants[i].name)
                sb.append(",\"payloads\":[")
                for j in 0..e.variants[i].payloads.len {
                    if j > 0 { sb.append(",") }
                    emit_type_expr(sb, &e.variants[i].payloads[j])
                }
                sb.append("]}")
            }
            sb.append("]}")
        }
        Error(e) => {
            sb.append("{\"kind\":\"Error\",")
            emit_span(sb, e.span)
            sb.append("}")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Patterns
// ─────────────────────────────────────────────────────────────────────────

fn emit_pattern(sb: &StringBuilder, p: &Pattern) {
    p.* match {
        Wildcard(w) => {
            sb.append("{\"kind\":\"Wildcard\",")
            emit_span(sb, w.span)
            sb.append("}")
        }
        Variable(v) => {
            sb.append("{\"kind\":\"Variable\",")
            emit_span(sb, v.span)
            emit_kv_string(sb, "name", v.name)
            sb.append("}")
        }
        Literal(lp) => {
            sb.append("{\"kind\":\"Literal\",")
            emit_span(sb, lp.span)
            emit_literal_payload(sb, lp.value)
            sb.append("}")
        }
        EnumVariant(ev) => {
            sb.append("{\"kind\":\"EnumVariant\",")
            emit_span(sb, ev.span)
            emit_kv_string(sb, "name", ev.name)
            sb.append(",\"qualifier\":")
            ev.qualifier match {
                Some(q) => emit_string(sb, q),
                None => sb.append("null"),
            }
            sb.append(",\"payloads\":[")
            for i in 0..ev.payloads.len {
                if i > 0 { sb.append(",") }
                emit_pattern(sb, &ev.payloads[i])
            }
            sb.append("]}")
        }
        Or(o) => {
            sb.append("{\"kind\":\"Or\",")
            emit_span(sb, o.span)
            sb.append(",\"alternatives\":[")
            for i in 0..o.alternatives.len {
                if i > 0 { sb.append(",") }
                emit_pattern(sb, &o.alternatives[i])
            }
            sb.append("]}")
        }
        Range(r) => {
            sb.append("{\"kind\":\"Range\",")
            emit_span(sb, r.span)
            emit_kv_bool(sb, "inclusive", r.inclusive)
            sb.append(",\"start\":")
            r.start match {
                Some(s) => emit_expr(sb, s),
                None => sb.append("null"),
            }
            sb.append(",\"end\":")
            r.end match {
                Some(e2) => emit_expr(sb, e2),
                None => sb.append("null"),
            }
            sb.append("}")
        }
        Struct(s) => {
            sb.append("{\"kind\":\"Struct\",")
            emit_span(sb, s.span)
            emit_kv_bool(sb, "has_rest", s.has_rest)
            sb.append(",\"type\":")
            emit_type_expr(sb, s.type_expr)
            sb.append(",\"fields\":[")
            for i in 0..s.fields.len {
                if i > 0 { sb.append(",") }
                sb.append("{\"kind\":\"Field\",")
                emit_span(sb, s.fields[i].span)
                emit_kv_string(sb, "name", s.fields[i].name)
                sb.append(",\"binding\":")
                s.fields[i].binding match {
                    Some(b) => emit_pattern(sb, b),
                    None => sb.append("null"),
                }
                sb.append("}")
            }
            sb.append("]}")
        }
        Tuple(t) => {
            sb.append("{\"kind\":\"Tuple\",")
            emit_span(sb, t.span)
            sb.append(",\"elements\":[")
            for i in 0..t.elements.len {
                if i > 0 { sb.append(",") }
                emit_pattern(sb, &t.elements[i])
            }
            sb.append("]}")
        }
    }
}
