using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace FLang.CLI;

/// <summary>
/// Cache for native dependency <c>.obj</c> files compiled from companion
/// <c>.c</c> sources (stdlib's <c>simd.c</c>, <c>bits.c</c>, <c>fs.c</c>,
/// <c>atomic.c</c>, plus any project-local C). Lives colocated with build
/// outputs at <c>build/cache/</c>.
///
/// Layout:
/// <code>
///   &lt;cacheDir&gt;/&lt;dep&gt;/&lt;name&gt;.obj
///   &lt;cacheDir&gt;/cache.json
/// </code>
///
/// Invalidation has two scopes:
/// <list type="bullet">
///   <item><b>flags_hash</b> at the top of <c>cache.json</c>: covers everything
///   that makes outputs binary-incompatible (compiler path, profile, cflags,
///   triple, flang version). Mismatch → wipe the cache directory and start
///   fresh.</item>
///   <item><b>per-entry mtime + size</b>: cheap freshness check. On mismatch,
///   fall back to a content hash before declaring a real miss (tolerates git
///   checkouts, <c>cp</c> without <c>-p</c>, NFS clock skew).</item>
/// </list>
///
/// Writes are not coordinated across processes. The natural failure mode under
/// concurrent writers (test harness) is "lost manifest entry → next miss
/// recompiles" — bounded redundant work, no correctness risk. Object files
/// themselves are published via atomic temp+rename.
/// </summary>
public sealed class BuildCache
{
    public delegate CompileResult CompileFn(string sourcePath, string outputObjPath);
    public record CompileResult(bool Success, string Stdout, string Stderr);

    private const int ManifestVersion = 1;
    private const string ManifestFileName = "cache.json";

    private readonly string _cacheDir;
    private readonly string _flagsHash;
    private readonly Dictionary<string, Entry> _entries;
    private readonly object _writeLock = new();

    private sealed record Entry(string Src, long SrcMtimeUnix, long SrcSize, string SrcHash);

    public BuildCache(string cacheDir, string flagsHash)
    {
        _cacheDir = cacheDir;
        _flagsHash = flagsHash;
        Directory.CreateDirectory(_cacheDir);
        _entries = LoadManifestOrInvalidate();
    }

    /// <summary>
    /// Hash of the inputs that make cached <c>.obj</c> files binary-incompatible
    /// with a fresh build. Stored at the top of the manifest; mismatch wipes the
    /// cache.
    /// </summary>
    public static string ComputeFlagsHash(
        CompilerConfig compilerConfig,
        bool releaseBuild,
        string flangVersion,
        IReadOnlyList<string>? compilerFlags)
    {
        var sb = new StringBuilder();
        sb.Append("compiler=").Append(compilerConfig.Name).Append('\n');
        sb.Append("path=").Append(compilerConfig.ExecutablePath).Append('\n');
        sb.Append("release=").Append(releaseBuild ? '1' : '0').Append('\n');
        sb.Append("cflags=");
        if (compilerFlags != null)
            foreach (var f in compilerFlags)
                sb.Append(f).Append('|');
        sb.Append('\n');
        sb.Append("triple=").Append(TargetTriple()).Append('\n');
        sb.Append("flang=").Append(flangVersion).Append('\n');

        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
        return "sha256:" + Convert.ToHexString(bytes).ToLowerInvariant();
    }

    /// <summary>
    /// Coarse OS+arch identifier folded into the flags hash. A toolchain change
    /// (different compiler binary) is already covered by the compiler-path
    /// component; this just guards against the same compiler producing different
    /// output for different architectures.
    /// </summary>
    public static string TargetTriple()
    {
        string os = RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "macos"
                  : RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? "linux"
                  : RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "windows"
                  : "unknown";
        string arch = RuntimeInformation.OSArchitecture switch
        {
            Architecture.Arm64 => "arm64",
            Architecture.X64 => "x86_64",
            Architecture.X86 => "x86",
            _ => RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()
        };
        return $"{os}-{arch}";
    }

    /// <summary>
    /// Resolve a cached <c>.obj</c> for <paramref name="sourcePath"/>, compiling
    /// via <paramref name="compileFn"/> on miss. Object writes use atomic
    /// temp+rename so a torn write is recovered on the next run.
    /// </summary>
    public string GetOrCompile(string depName, string sourcePath, CompileFn compileFn, out string? error)
    {
        error = null;

        var dep = SanitizeDepName(depName);
        var basename = Path.GetFileNameWithoutExtension(sourcePath);
        var key = $"{dep}/{basename}.obj";
        var objPath = Path.Combine(_cacheDir, dep, basename + ".obj");
        Directory.CreateDirectory(Path.GetDirectoryName(objPath)!);

        var fi = new FileInfo(sourcePath);
        var srcMtime = ((DateTimeOffset)fi.LastWriteTimeUtc).ToUnixTimeSeconds();
        var srcSize = fi.Length;

        if (TryHit(key, objPath, sourcePath, srcMtime, srcSize))
            return objPath;

        var tmpSuffix = $".tmp.{Environment.ProcessId}-{Guid.NewGuid():N}";
        var tmpObj = objPath + tmpSuffix;

        var compile = compileFn(sourcePath, tmpObj);
        if (!compile.Success)
        {
            error = $"failed to compile {sourcePath}:\n{compile.Stdout}\n{compile.Stderr}".TrimEnd();
            SafeDelete(tmpObj);
            return objPath;
        }

        try
        {
            File.Move(tmpObj, objPath, overwrite: true);
            var hash = "sha256:" + HashFile(sourcePath);
            UpsertEntry(key, sourcePath, srcMtime, srcSize, hash);
            return objPath;
        }
        catch (Exception ex)
        {
            error = $"cache: failed to publish {objPath}: {ex.Message}";
            SafeDelete(tmpObj);
            return objPath;
        }
    }

    // ----- internals ------------------------------------------------------

    private bool TryHit(string key, string objPath, string srcPath, long srcMtime, long srcSize)
    {
        if (!File.Exists(objPath)) return false;

        Entry? entry;
        lock (_writeLock) { _entries.TryGetValue(key, out entry); }
        if (entry == null) return false;

        if (entry.SrcMtimeUnix == srcMtime && entry.SrcSize == srcSize)
            return true;

        // Metadata drifted but content might be unchanged (git checkout, cp
        // without -p, NFS). Confirm with a content hash before invalidating.
        var actual = "sha256:" + HashFile(srcPath);
        if (actual != entry.SrcHash) return false;

        // Same bytes; refresh metadata so the next lookup is cheap again.
        UpsertEntry(key, srcPath, srcMtime, srcSize, entry.SrcHash);
        return true;
    }

    private void UpsertEntry(string key, string srcPath, long srcMtime, long srcSize, string srcHash)
    {
        lock (_writeLock)
        {
            _entries[key] = new Entry(srcPath, srcMtime, srcSize, srcHash);
            FlushUnsafe();
        }
    }

    private Dictionary<string, Entry> LoadManifestOrInvalidate()
    {
        var manifest = Path.Combine(_cacheDir, ManifestFileName);
        if (!File.Exists(manifest)) return new();

        try
        {
            using var fs = File.OpenRead(manifest);
            using var doc = JsonDocument.Parse(fs);
            var root = doc.RootElement;

            var version = root.TryGetProperty("version", out var vEl) ? vEl.GetInt32() : 0;
            var flags = root.TryGetProperty("flags_hash", out var fEl) ? fEl.GetString() ?? "" : "";

            if (version != ManifestVersion || flags != _flagsHash)
            {
                WipeCacheContents();
                return new();
            }

            var entries = new Dictionary<string, Entry>();
            if (root.TryGetProperty("entries", out var entriesEl) && entriesEl.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in entriesEl.EnumerateObject())
                {
                    var e = prop.Value;
                    entries[prop.Name] = new Entry(
                        Src: e.GetProperty("src").GetString() ?? "",
                        SrcMtimeUnix: e.GetProperty("src_mtime_unix").GetInt64(),
                        SrcSize: e.GetProperty("src_size").GetInt64(),
                        SrcHash: e.GetProperty("src_hash").GetString() ?? "");
                }
            }
            return entries;
        }
        catch
        {
            // Corrupt manifest — treat like an invalidation.
            WipeCacheContents();
            return new();
        }
    }

    private void WipeCacheContents()
    {
        try
        {
            foreach (var f in Directory.EnumerateFiles(_cacheDir))
            {
                try { File.Delete(f); } catch { }
            }
            foreach (var d in Directory.EnumerateDirectories(_cacheDir))
            {
                try { Directory.Delete(d, recursive: true); } catch { }
            }
        }
        catch { /* best effort */ }
    }

    private void FlushUnsafe()
    {
        var manifest = Path.Combine(_cacheDir, ManifestFileName);
        var tmp = manifest + $".tmp.{Environment.ProcessId}-{Guid.NewGuid():N}";
        try
        {
            using (var fs = File.Create(tmp))
            using (var writer = new Utf8JsonWriter(fs, new JsonWriterOptions { Indented = true }))
            {
                writer.WriteStartObject();
                writer.WriteNumber("version", ManifestVersion);
                writer.WriteString("flags_hash", _flagsHash);
                writer.WriteStartObject("entries");
                foreach (var (k, v) in _entries.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                {
                    writer.WriteStartObject(k);
                    writer.WriteString("src", v.Src);
                    writer.WriteNumber("src_mtime_unix", v.SrcMtimeUnix);
                    writer.WriteNumber("src_size", v.SrcSize);
                    writer.WriteString("src_hash", v.SrcHash);
                    writer.WriteEndObject();
                }
                writer.WriteEndObject();
                writer.WriteEndObject();
            }
            File.Move(tmp, manifest, overwrite: true);
        }
        catch
        {
            SafeDelete(tmp);
        }
    }

    private static string HashFile(string path)
    {
        using var fs = File.OpenRead(path);
        var bytes = SHA256.HashData(fs);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    private static string SanitizeDepName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
            sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
        var sanitized = sb.ToString();
        return string.IsNullOrWhiteSpace(sanitized) ? "unknown" : sanitized;
    }

    private static void SafeDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
