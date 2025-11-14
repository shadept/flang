using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.CLI;
using FLang.Codegen.C;
using FLang.Core;
using FLang.IR;
using FLang.Semantics;

// Parse command-line arguments
string? inputFilePath = null;
string? stdlibPath = null;
string? emitFir = null;
var demoDiagnostics = false;
var releaseBuild = false;

for (var i = 0; i < args.Length; i++)
    if (args[i] == "--stdlib-path" && i + 1 < args.Length)
        stdlibPath = args[++i];
    else if (args[i] == "--emit-fir" && i + 1 < args.Length)
        emitFir = args[++i];
    else if (args[i] == "--demo-diagnostics")
        demoDiagnostics = true;
    else if (args[i] == "--release")
        releaseBuild = true;
    else if (!args[i].StartsWith("--")) inputFilePath = args[i];

if (demoDiagnostics)
{
    DiagnosticDemo.Run();
    return;
}

if (inputFilePath == null)
{
    Console.WriteLine("Usage: flang [options] <file>");
    Console.WriteLine("Options:");
    Console.WriteLine("  --stdlib-path <path>    Path to standard library directory");
    Console.WriteLine("  --emit-fir <file>       Emit FIR (intermediate representation) to file (use '-' for stdout)");
    Console.WriteLine("  --release               Enable C backend optimization (passes -O2 /O2)");
    Console.WriteLine("  --demo-diagnostics      Show diagnostic system demo");
    return;
}

// Set the default stdlib path if not provided
if (stdlibPath == null) stdlibPath = Path.Combine(AppContext.BaseDirectory, "stdlib");

var compilation = new Compilation();
compilation.StdlibPath = stdlibPath;

// Compile all modules (entry point + imports)
var moduleCompiler = new ModuleCompiler(compilation);
var parsedModules = moduleCompiler.CompileModules(inputFilePath);

// Report module loading/import resolution diagnostics (e.g., unresolved imports)
if (moduleCompiler.Diagnostics.Any())
{
    foreach (var diagnostic in moduleCompiler.Diagnostics)
        DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: Module loading failed with {moduleCompiler.Diagnostics.Count} error(s)");
    Environment.Exit(1);
}

// Type checking pass
var typeSolver = new TypeSolver(compilation);

// First pass: collect all struct definitions and function signatures from all modules
foreach (var module in parsedModules.Values)
{
    typeSolver.CollectStructDefinitions(module);
    typeSolver.CollectFunctionSignatures(module);
}

// Second pass: type check all function bodies
foreach (var module in parsedModules.Values) typeSolver.CheckModuleBodies(module);

// Check for type errors
if (typeSolver.Diagnostics.Any())
{
    foreach (var diagnostic in typeSolver.Diagnostics) DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: Type checking failed with {typeSolver.Diagnostics.Count} error(s)");
    Environment.Exit(1);
}

// Lower all functions from all modules to FIR
var allFunctions = new List<Function>();
var loweringDiagnostics = new List<Diagnostic>();

foreach (var module in parsedModules.Values)
foreach (var functionNode in module.Functions)
{
    var (irFunction, diagnostics) = AstLowering.Lower(functionNode, compilation, typeSolver);
    allFunctions.Add(irFunction);
    loweringDiagnostics.AddRange(diagnostics);
}

// Check for lowering errors
if (loweringDiagnostics.Count != 0)
{
    foreach (var diagnostic in loweringDiagnostics) DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: FIR lowering failed with {loweringDiagnostics.Count} error(s)");
    Environment.Exit(1);
}

if (allFunctions.Count == 0)
{
    Console.Error.WriteLine("Error: No functions found in any module");
    Environment.Exit(1);
}

// Emit FIR if requested (for all functions)
if (emitFir != null)
{
    var firBuilder = new StringBuilder();
    foreach (var func in allFunctions) firBuilder.AppendLine(FirPrinter.Print(func));

    var firOutput = firBuilder.ToString();
    if (emitFir == "-")
    {
        Console.WriteLine("=== FIR ===");
        Console.WriteLine(firOutput);
    }
    else
    {
        File.WriteAllText(emitFir, firOutput);
        Console.WriteLine($"FIR emitted to {emitFir}");
    }
}

// Generate C code for all functions with proper hoisting/deduplication
var headerBuilder = new StringBuilder();
headerBuilder.AppendLine("#include <stdio.h>");
headerBuilder.AppendLine("#include <stdint.h>");
headerBuilder.AppendLine();

// Collect struct definitions and extern prototypes uniquely
var structBlocks = new Dictionary<string, string>(); // name -> block
var externPrototypes = new HashSet<string>();
var functionBodies = new StringBuilder();

foreach (var func in allFunctions)
{
    var funcCode = CCodeGenerator.Generate(func);
    var lines = funcCode.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);

    bool inStruct = false;
    string currentStructName = "";
    var currentStructLines = new List<string>();

    foreach (var line in lines)
    {
        if (string.IsNullOrWhiteSpace(line) || line.StartsWith("#include"))
            continue;

        var trimmed = line.TrimStart();
        if (!inStruct && trimmed.StartsWith("struct ") && trimmed.Contains("{"))
        {
            // Begin struct block
            var afterStruct = trimmed.Substring("struct ".Length);
            var name = afterStruct.Split(new[] { ' ', '{' }, StringSplitOptions.RemoveEmptyEntries)[0];
            inStruct = true;
            currentStructName = name;
            currentStructLines.Clear();
            currentStructLines.Add(line);
            continue;
        }
        if (inStruct)
        {
            currentStructLines.Add(line);
            if (trimmed.StartsWith("};"))
            {
                // End of struct block
                var block = string.Join("\n", currentStructLines);
                if (!structBlocks.ContainsKey(currentStructName))
                    structBlocks[currentStructName] = block;
                inStruct = false;
                currentStructName = "";
                currentStructLines.Clear();
            }
            continue;
        }

        if (trimmed.StartsWith("extern "))
        {
            externPrototypes.Add(line.Trim());
            continue;
        }

        // Otherwise, it's part of a function or static data
        functionBodies.AppendLine(line);
    }
}

// Emit unique struct definitions first
foreach (var block in structBlocks.Values)
{
    headerBuilder.AppendLine(block);
    headerBuilder.AppendLine();
}

// Emit prototypes for all non-foreign functions to avoid forward-declaration issues
foreach (var f in allFunctions)
{
    if (f.IsForeign) continue;
    var plist = string.Join(", ", f.Parameters.Select(p => $"{TypeRegistry.ToCType(p.Type)} {p.Name}"));
    if (f.Parameters.Count == 0) plist = "void";
    headerBuilder.AppendLine($"{TypeRegistry.ToCType(f.ReturnType)} {f.Name}({plist});");
}

// Emit unique extern prototypes next
foreach (var proto in externPrototypes)
    headerBuilder.AppendLine(proto);

headerBuilder.AppendLine();

var cCode = headerBuilder.ToString() + functionBodies.ToString();

var cFilePath = Path.ChangeExtension(inputFilePath, ".c");
File.WriteAllText(cFilePath, cCode);

var outputFilePath = Path.ChangeExtension(inputFilePath, ".exe");

// Build compiler list with cl.exe path resolution on Windows
var compilersList = new List<(string, string, Dictionary<string, string>?)>();

var gccArgs = new List<string>();
if (releaseBuild) gccArgs.Add("-O2");
gccArgs.Add($"-o \"{outputFilePath}\"");
gccArgs.Add($"\"{cFilePath}\"");
compilersList.Add(("gcc", string.Join(" ", gccArgs), null));

if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
{
    var (clPath, clEnv) = FindClExeWithEnvironment();
    var msvcArgs = new List<string> { "/nologo" };
    if (releaseBuild) msvcArgs.Add("/O2");
    msvcArgs.Add($"/Fe\"{outputFilePath}\"");
    msvcArgs.Add($"\"{cFilePath}\"");

    if (clPath != null)
        compilersList.Add((clPath, string.Join(" ", msvcArgs), clEnv));
    else
        // Fallback to hoping cl.exe is in PATH with proper environment
        compilersList.Add(("cl.exe", string.Join(" ", msvcArgs), null));
}

var compilers = compilersList.ToArray();

var compiled = false;
foreach (var (compiler, arguments, environment) in compilers)
{
    var startInfo = new ProcessStartInfo
    {
        FileName = compiler,
        Arguments = arguments,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        CreateNoWindow = true
    };

    // Add custom environment variables if provided (needed for cl.exe)
    if (environment != null)
        foreach (var (key, value) in environment)
            startInfo.EnvironmentVariables[key] = value;

    var process = new Process { StartInfo = startInfo };

    try
    {
        process.Start();
        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            Console.WriteLine($"C compiler ({compiler}) failed:");
            var output = process.StandardOutput.ReadToEnd();
            Console.WriteLine(output);
        }
        else
        {
            Console.WriteLine($"Successfully compiled to {outputFilePath}");
            compiled = true;

            // Clean up intermediate files (cl.exe creates .obj files)
            // Check both next to source file and in current directory
            var objFilePath = Path.ChangeExtension(inputFilePath, ".obj");
            if (File.Exists(objFilePath)) File.Delete(objFilePath);

            var baseNameObj = Path.GetFileNameWithoutExtension(inputFilePath) + ".obj";
            if (File.Exists(baseNameObj)) File.Delete(baseNameObj);

            break;
        }
    }
    catch (Win32Exception e)
    {
        // Try next compiler
    }
}

if (!compiled)
{
    Console.Error.WriteLine(
        $"Error: Could not find any C compiler. Tried: {string.Join(", ", compilers.Select(c => c.Item1))}");
    Environment.Exit(1);
}

static (string?, Dictionary<string, string>?) FindClExeWithEnvironment()
{
    // Try vswhere first (most reliable for modern VS installations)
    var vswherePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        "Microsoft Visual Studio", "Installer", "vswhere.exe");

    string? vsInstallPath = null;

    if (File.Exists(vswherePath))
        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = vswherePath,
                Arguments =
                    "-latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });

            if (process != null)
            {
                vsInstallPath = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit();

                if (string.IsNullOrEmpty(vsInstallPath) || !Directory.Exists(vsInstallPath))
                    vsInstallPath = null;
            }
        }
        catch
        {
        }

    // Fallback: check common installation directories
    if (vsInstallPath == null)
    {
        var commonBasePaths = new[]
        {
            @"C:\Program Files (x86)\Microsoft Visual Studio\2022",
            @"C:\Program Files (x86)\Microsoft Visual Studio\2019",
            @"C:\Program Files (x86)\Microsoft Visual Studio\2017"
        };

        var editions = new[] { "Community", "Professional", "Enterprise", "BuildTools" };

        foreach (var basePath in commonBasePaths)
        {
            foreach (var edition in editions)
            {
                var testPath = Path.Combine(basePath, edition);
                if (Directory.Exists(testPath))
                {
                    vsInstallPath = testPath;
                    break;
                }
            }

            if (vsInstallPath != null) break;
        }
    }

    if (vsInstallPath == null)
        return (null, null);

    // Find the MSVC toolset version
    var vcToolsPath = Path.Combine(vsInstallPath, "VC", "Tools", "MSVC");
    if (!Directory.Exists(vcToolsPath))
        return (null, null);

    string? toolsetVersion = null;
    try
    {
        toolsetVersion = Directory.GetDirectories(vcToolsPath)
            .Select(Path.GetFileName)
            .OrderByDescending(v => v)
            .FirstOrDefault();
    }
    catch
    {
    }

    if (toolsetVersion == null)
        return (null, null);

    var clPath = Path.Combine(vcToolsPath, toolsetVersion, "bin", "Hostx64", "x64", "cl.exe");
    if (!File.Exists(clPath))
        return (null, null);

    // Set up the environment variables needed for cl.exe
    var env = new Dictionary<string, string>();

    var toolsetDir = Path.Combine(vcToolsPath, toolsetVersion);
    var includeDir = Path.Combine(toolsetDir, "include");
    var libDir = Path.Combine(toolsetDir, "lib", "x64");

    // Windows SDK paths
    var windowsSdkDir = @"C:\Program Files (x86)\Windows Kits\10";
    string? sdkVersion = null;

    if (Directory.Exists(windowsSdkDir))
    {
        var sdkIncludePath = Path.Combine(windowsSdkDir, "Include");
        if (Directory.Exists(sdkIncludePath))
            try
            {
                sdkVersion = Directory.GetDirectories(sdkIncludePath)
                    .Select(Path.GetFileName)
                    .OrderByDescending(v => v)
                    .FirstOrDefault();
            }
            catch
            {
            }
    }

    // Build INCLUDE path
    var includePaths = new List<string> { includeDir };
    if (sdkVersion != null)
    {
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "ucrt"));
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "um"));
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "shared"));
    }

    env["INCLUDE"] = string.Join(";", includePaths);

    // Build LIB path
    var libPaths = new List<string> { libDir };
    if (sdkVersion != null)
    {
        libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "ucrt", "x64"));
        libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "um", "x64"));
    }

    env["LIB"] = string.Join(";", libPaths);

    // Add cl.exe directory to PATH
    var binDir = Path.GetDirectoryName(clPath);
    if (binDir != null) env["PATH"] = binDir + ";" + Environment.GetEnvironmentVariable("PATH");

    return (clPath, env);
}