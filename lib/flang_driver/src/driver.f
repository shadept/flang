// flang_driver — the compile pipeline as a library: source text in, a
// checked `AnalyzedUnit` out (AST + type-check result + combined parse and
// check diagnostics). This is the single analysis entry point shared by
// every front-end exe — `flang build`, `flang test`, and the LSP — each of
// which is a thin `main` over `analyze`.
//
// The library owns the pipeline but not its edges: file reading and
// diagnostic *rendering* are the caller's concern (the LSP reads buffers
// and emits protocol diagnostics; the CLI reads files and prints to a
// terminal).
//
// Ownership: an `AnalyzedUnit` owns its `source`. The projected AST stores
// string views into the source buffer (flang_parser/projector.f), so the
// source must outlive the `Module`. Tokens and the CST are dropped inside
// `analyze` once the AST exists.

import std.allocator
import std.list
import std.option
import std.string
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_parser.ast
import flang_core.diagnostic
import flang_typer.checker
import flang_typer.result

// A fully analysed compilation unit. `checked` is false when the source
// failed to parse — `result` is then an empty placeholder.
pub type AnalyzedUnit = struct {
    source: OwnedString
    module: Module
    result: TypeCheckResult
    checked: bool
    diagnostics: List(Diagnostic)
}

// Analyse source text: lex → parse → project → type-check. Consumes
// `source` (the unit owns it). `path` labels the module for FQN
// construction and diagnostics; it need not name a real file.
pub fn analyze(source: OwnedString, path: String, allocator: &Allocator? = null) AnalyzedUnit {
    let alloc = allocator.or_global()
    let diagnostics: List(Diagnostic) = list(0, alloc)
    const src = source.as_view()

    let lx = lexer(src, alloc)
    let tokens = lx.tokenize()
    let p = parser(tokens, alloc)
    const cst = p.parse_module()
    const module = project_module(cst, 0i32, alloc)

    // The AST views `source`, not the token structs — tokens and the parser
    // are dead once the Module exists. Drain parse diagnostics first so they
    // survive `p.deinit()`.
    drain_diagnostics(&diagnostics, &p.diagnostics)
    p.deinit()
    tokens.deinit()

    // A file that didn't parse is not type-checked.
    let checked = count_errors(&diagnostics) == 0
    let result = empty_result(alloc)
    if checked {
        let modules: List(Module) = list(1, alloc)
        modules.push(module)
        let paths: List(String) = list(1, alloc)
        paths.push(path)

        let chk = checker(alloc)
        result = check_all(&chk, &modules, &paths)
        drain_diagnostics(&diagnostics, &chk.diagnostics)
        chk.deinit()

        // `push` copied the struct; `module` still owns the arena. Forget
        // the alias before freeing the list so the arena isn't double-freed.
        modules.clear()
        modules.deinit()
        paths.deinit()
    }

    return .{
        source = source,
        module = module,
        result = result,
        checked = checked,
        diagnostics = diagnostics,
    }
}

pub fn deinit(self: &AnalyzedUnit) {
    self.diagnostics.deinit()
    self.module.deinit()
    self.source.deinit()
    // ponytail: the TypeCheckResult is leaked — flang_typer has no
    // result.deinit() yet. Fine for one-shot build/test; add result.deinit()
    // before the LSP re-analyses on every keystroke. See docs/known-issues.md.
}

// Error-severity diagnostics only — warnings and hints don't fail a build.
pub fn error_count(self: &AnalyzedUnit) usize {
    return count_errors(&self.diagnostics)
}

// Move every diagnostic from `src` into `dst`. `src.clear()` resets the
// length without deiniting elements, so the moved OwnedString messages are
// owned once (by `dst`) and never double-freed.
fn drain_diagnostics(dst: &List(Diagnostic), src: &List(Diagnostic)) {
    for i in 0..src.len {
        dst.push(src[i])
    }
    src.clear()
}

fn count_errors(diags: &List(Diagnostic)) usize {
    let n: usize = 0
    for i in 0..diags.len {
        if diags[i].severity == Severity.Error { n = n + 1 }
    }
    return n
}
