using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using FLang.Lsp;
using FLang.Semantics;
using Microsoft.Extensions.Logging.Abstractions;

namespace FLang.Tests;

public class ReferenceFinderTests
{
    // Mirror of HmTypeCheckerTests' setup: parse source, run the type checker
    // phases the LSP workspace runs, return a FileAnalysisResult suitable for
    // driving ReferenceFinder directly (without going through the LSP server).
    private static readonly string AssemblyPath = Path.GetDirectoryName(typeof(ReferenceFinderTests).Assembly.Location)!;
    private static readonly string ProjectRoot = Path.GetFullPath(Path.Combine(AssemblyPath, "..", "..", "..", "..", ".."));
    private static readonly string StdlibPath = Path.Combine(ProjectRoot, "stdlib");

    private static (FileAnalysisResult Analysis, int FileId, int Cursor, string TempPath) Analyze(string sourceWithCursor)
    {
        var cursorIdx = sourceWithCursor.IndexOf('|');
        if (cursorIdx < 0) throw new ArgumentException("Source must contain a '|' cursor marker");
        var source = sourceWithCursor.Remove(cursorIdx, 1);

        var tempFile = Path.GetTempFileName() + ".f";
        File.WriteAllText(tempFile, source);

        var compilation = new Compilation
        {
            StdlibPath = StdlibPath,
            WorkingDirectory = Path.GetDirectoryName(tempFile)!,
        };
        compilation.IncludePaths.Add(StdlibPath);

        var moduleCompiler = new ModuleCompiler(compilation, NullLogger<ModuleCompiler>.Instance);
        var parsedModules = moduleCompiler.CompileModules(tempFile);

        var checker = new HmTypeChecker(compilation);

        // Prelude auto-import, same as the LSP workspace does
        const string preludeModulePath = "core.prelude";
        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            if (modulePath != preludeModulePath)
                compilation.RegisterImport(modulePath, preludeModulePath, isPublic: false);
            foreach (var import in kvp.Value.Imports)
            {
                var importedPath = string.Join(".", import.Path);
                compilation.RegisterImport(modulePath, importedPath, import.IsPublic);
            }
        }

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            checker.CollectNominalTypes(kvp.Value, modulePath);
        }
        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            checker.ResolveNominalTypes(kvp.Value, modulePath);
        }
        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            checker.CollectFunctionSignatures(kvp.Value, modulePath);
        }
        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            checker.CheckModuleBodies(kvp.Value, modulePath);
        }

        var result = checker.BuildResult();
        var allDiags = moduleCompiler.Diagnostics.Concat(checker.Diagnostics).ToList();

        var analysis = new FileAnalysisResult(allDiags, compilation, parsedModules, result);

        var fileId = -1;
        var normalizedTemp = Path.GetFullPath(tempFile);
        for (var i = 0; i < compilation.Sources.Count; i++)
        {
            if (Path.GetFullPath(compilation.Sources[i].FileName) == normalizedTemp)
            {
                fileId = i;
                break;
            }
        }
        Assert.True(fileId >= 0, "test file not found in compilation sources");

        return (analysis, fileId, cursorIdx, tempFile);
    }

    private static ModuleNode GetTestModule(FileAnalysisResult analysis, string tempPath)
    {
        var normalizedTemp = Path.GetFullPath(tempPath);
        return analysis.ParsedModules[normalizedTemp];
    }

    private static List<string> GetReferenceTexts(List<SourceSpan> spans, FileAnalysisResult analysis)
    {
        var texts = new List<string>();
        foreach (var span in spans)
        {
            if (span.FileId < 0) continue;
            var src = analysis.Compilation.Sources[span.FileId];
            var end = Math.Min(span.Index + span.Length, src.Text.Length);
            texts.Add(src.Text[span.Index..end]);
        }
        return texts;
    }

    [Fact]
    public void Finds_direct_function_call_references()
    {
        var src = """
            fn fo|o() i32 { return 42 }
            pub fn main() i32 { return foo() + foo() }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<FunctionRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: false);
        Assert.Equal(2, refs.Count);
        Assert.All(GetReferenceTexts(refs, analysis), t => Assert.Equal("foo", t));
    }

    [Fact]
    public void Finds_function_references_from_call_site()
    {
        var src = """
            fn foo() i32 { return 42 }
            pub fn main() i32 { return fo|o() + foo() }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<FunctionRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: true);
        Assert.Equal(3, refs.Count);
    }

    [Fact]
    public void Finds_local_variable_references()
    {
        // Cursor goes mid-identifier so the position falls strictly inside the
        // NameSpan (which has exclusive end). Single-char names can only host
        // the cursor with `|<char>` (cursor before), which is awkward to read.
        var src = """
            pub fn main() i32 {
                let xx : i32 = 10
                let y  : i32 = x|x + xx
                return y
            }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<LocalDeclRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: false);
        Assert.Equal(2, refs.Count);
        Assert.All(GetReferenceTexts(refs, analysis), t => Assert.Equal("xx", t));
    }

    [Fact]
    public void Finds_parameter_references()
    {
        var src = """
            pub fn double(va|l: i32) i32 { return val + val }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<LocalDeclRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: false);
        Assert.Equal(2, refs.Count);
        Assert.All(GetReferenceTexts(refs, analysis), t => Assert.Equal("val", t));
    }

    [Fact]
    public void Finds_struct_type_references()
    {
        var src = """
            type Po|int = struct { x: i32, y: i32 }
            fn make() Point { return Point { x = 1, y = 2 } }
            pub fn use_it(p: Point) i32 { return p.x }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<NominalTypeRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: false);
        // 3 type references: return type, struct construction, parameter type
        Assert.Equal(3, refs.Count);
        Assert.All(GetReferenceTexts(refs, analysis), t => Assert.Equal("Point", t));
    }

    [Fact]
    public void Finds_struct_field_references_via_member_access()
    {
        var src = """
            type Point = struct { xx|x: i32, y: i32 }
            fn get_xxx(p: Point) i32 { return p.xxx }
            pub fn get_xxx2(p: Point) i32 { return p.xxx }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.IsType<StructFieldRefTarget>(target);

        var refs = ReferenceFinder.FindReferences(target!, analysis, includeDeclaration: false);
        Assert.Equal(2, refs.Count);
        Assert.All(GetReferenceTexts(refs, analysis), t => Assert.Equal("xxx", t));
    }

    [Fact]
    public void Function_target_matches_across_separate_analyses()
    {
        // Regression: when the cursor is on a function decl in file A, downstream
        // callers in file B only exist in B's own analysis (which transitively
        // includes A). The two analyses have different Compilations, so the same
        // logical source location gets different SourceSpan.FileId values.
        // FunctionRefTarget uses path-based identity so matches still succeed.
        var libDir = Path.Combine(Path.GetTempPath(), $"flang_refs_lib_{Guid.NewGuid():N}");
        Directory.CreateDirectory(libDir);
        var libPath = Path.Combine(libDir, "mylib.f");
        File.WriteAllText(libPath, "pub fn add_o|ne(x: i32) i32 { return x + 1 }\n");

        var (libAnalysis, libFileId, libCursor, _) = AnalyzeExistingFile(libPath);
        var libModule = libAnalysis.ParsedModules[Path.GetFullPath(libPath)];
        var target = ReferenceFinder.ResolveTargetAt(libModule, libFileId, libCursor, libAnalysis);
        Assert.IsType<FunctionRefTarget>(target);
        var fnTarget = (FunctionRefTarget)target!;
        Assert.Equal(Path.GetFullPath(libPath), fnTarget.FilePath);

        // Second file imports the first, calling the function twice.
        var callerSrc = $$"""
            import mylib
            pub fn main() i32 { return add_one(1) + add_one(2) }
            """;
        var callerPath = Path.Combine(libDir, "caller.f");
        File.WriteAllText(callerPath, callerSrc);
        var (callerAnalysis, _, _, _) = AnalyzeExistingFile(callerPath, extraIncludePath: libDir);

        // Sanity: the two analyses have different Compilations.
        Assert.NotSame(libAnalysis.Compilation, callerAnalysis.Compilation);

        var libRefs = ReferenceFinder.FindReferences(target!, libAnalysis, includeDeclaration: false);
        var callerRefs = ReferenceFinder.FindReferences(target!, callerAnalysis, includeDeclaration: false);

        Assert.Empty(libRefs); // no callers inside the lib itself
        Assert.Equal(2, callerRefs.Count); // both calls resolve across analyses

        try { Directory.Delete(libDir, recursive: true); } catch { /* ignore */ }
    }

    private static (FileAnalysisResult Analysis, int FileId, int Cursor, string TempPath) AnalyzeExistingFile(
        string path, string? extraIncludePath = null)
    {
        var raw = File.ReadAllText(path);
        var cursorIdx = raw.IndexOf('|');
        if (cursorIdx >= 0)
        {
            File.WriteAllText(path, raw.Remove(cursorIdx, 1));
        }
        else
        {
            cursorIdx = 0;
        }

        var compilation = new Compilation
        {
            StdlibPath = StdlibPath,
            WorkingDirectory = Path.GetDirectoryName(path)!,
        };
        compilation.IncludePaths.Add(StdlibPath);
        if (extraIncludePath != null) compilation.IncludePaths.Add(extraIncludePath);
        compilation.IncludePaths.Add(compilation.WorkingDirectory);

        var moduleCompiler = new ModuleCompiler(compilation, NullLogger<ModuleCompiler>.Instance);
        var parsedModules = moduleCompiler.CompileModules(path);

        var checker = new HmTypeChecker(compilation);
        const string preludeModulePath = "core.prelude";
        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(
                kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            if (modulePath != preludeModulePath)
                compilation.RegisterImport(modulePath, preludeModulePath, isPublic: false);
            foreach (var import in kvp.Value.Imports)
            {
                var importedPath = string.Join(".", import.Path);
                compilation.RegisterImport(modulePath, importedPath, import.IsPublic);
            }
        }

        foreach (var phase in new Action<Frontend.Ast.Declarations.ModuleNode, string>[] {
            checker.CollectNominalTypes,
            checker.ResolveNominalTypes,
            checker.CollectFunctionSignatures,
            (m, p) => checker.CheckModuleBodies(m, p),
        })
        {
            foreach (var kvp in parsedModules)
            {
                var modulePath = HmTypeChecker.DeriveModulePath(
                    kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                phase(kvp.Value, modulePath);
            }
        }

        var result = checker.BuildResult();
        var analysis = new FileAnalysisResult(
            [.. moduleCompiler.Diagnostics, .. checker.Diagnostics], compilation, parsedModules, result);

        var fileId = -1;
        var normalized = Path.GetFullPath(path);
        for (var i = 0; i < compilation.Sources.Count; i++)
        {
            if (Path.GetFullPath(compilation.Sources[i].FileName) == normalized) { fileId = i; break; }
        }
        Assert.True(fileId >= 0);

        return (analysis, fileId, cursorIdx, path);
    }

    [Fact]
    public void Cursor_on_nothing_returns_null()
    {
        var src = """
            fn foo() i32 { return 42 }
            |
            pub fn bar() i32 { return 1 }
            """;
        var (analysis, fileId, cursor, tempPath) = Analyze(src);
        var module = GetTestModule(analysis, tempPath);

        var target = ReferenceFinder.ResolveTargetAt(module, fileId, cursor, analysis);
        Assert.Null(target);
    }
}
