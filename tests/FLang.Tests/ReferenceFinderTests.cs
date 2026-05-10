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
