using FLang.CLI;

namespace FLang.Tests;

/// <summary>
/// Unit tests for <see cref="BuildCache"/>. Avoid invoking a real C compiler:
/// <see cref="BuildCache.GetOrCompile"/> takes a delegate, so we substitute a
/// recording fake that just writes a marker file and counts invocations.
/// </summary>
public class BuildCacheTests : IDisposable
{
    private readonly string _tempDir;

    public BuildCacheTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "flang_cache_test_" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private string CreateSource(string name, string contents)
    {
        var path = Path.Combine(_tempDir, name);
        File.WriteAllText(path, contents);
        return path;
    }

    private string CacheDir => Path.Combine(_tempDir, "cache");

    private (BuildCache.CompileFn fn, Func<int> count) RecordingCompiler()
    {
        var calls = 0;
        BuildCache.CompileFn fn = (src, obj) =>
        {
            calls++;
            File.WriteAllBytes(obj, [(byte)'O', (byte)'B', (byte)'J']);
            return new BuildCache.CompileResult(true, "", "");
        };
        return (fn, () => calls);
    }

    [Fact]
    public void Miss_then_hit_only_compiles_once()
    {
        var src = CreateSource("foo.c", "int x;");
        var cache = new BuildCache(CacheDir, "sha256:flagsA");
        var (fn, count) = RecordingCompiler();

        cache.GetOrCompile("stdlib", src, fn, out var err1);
        cache.GetOrCompile("stdlib", src, fn, out var err2);

        Assert.Null(err1);
        Assert.Null(err2);
        Assert.Equal(1, count());
    }

    [Fact]
    public void Touching_source_without_changing_content_is_a_hit()
    {
        var src = CreateSource("foo.c", "int x;");
        var cache = new BuildCache(CacheDir, "sha256:flagsA");
        var (fn, count) = RecordingCompiler();

        cache.GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());

        // Push mtime forward without changing bytes — simulates `touch`, git
        // checkout, cp without -p, etc. mtime+size mismatches but content hash
        // matches → cache should refresh metadata and report a hit.
        File.SetLastWriteTimeUtc(src, DateTime.UtcNow.AddMinutes(5));

        // Re-open the cache so the in-memory entry is reloaded from disk
        // (matches the real-world "next build" scenario).
        var cache2 = new BuildCache(CacheDir, "sha256:flagsA");
        cache2.GetOrCompile("stdlib", src, fn, out _);

        Assert.Equal(1, count());
    }

    [Fact]
    public void Editing_source_content_is_a_miss()
    {
        var src = CreateSource("foo.c", "int x;");
        var cache = new BuildCache(CacheDir, "sha256:flagsA");
        var (fn, count) = RecordingCompiler();

        cache.GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());

        // Real edit — content and size both change.
        File.WriteAllText(src, "int x; int y;");

        var cache2 = new BuildCache(CacheDir, "sha256:flagsA");
        cache2.GetOrCompile("stdlib", src, fn, out _);

        Assert.Equal(2, count());
    }

    [Fact]
    public void Flags_change_wipes_the_cache()
    {
        var src = CreateSource("foo.c", "int x;");
        var (fn, count) = RecordingCompiler();

        new BuildCache(CacheDir, "sha256:debug").GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());

        // Different flags hash → constructor wipes the cache directory and
        // starts fresh. Next lookup is a miss.
        new BuildCache(CacheDir, "sha256:release").GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(2, count());

        // The .obj file from the debug build should no longer be in the cache
        // dir under the old name (flags changed → wipe). It will exist again
        // because we just compiled, but only one entry should be present.
        var manifest = File.ReadAllText(Path.Combine(CacheDir, "cache.json"));
        Assert.Contains("\"flags_hash\": \"sha256:release\"", manifest);
        Assert.DoesNotContain("\"flags_hash\": \"sha256:debug\"", manifest);
    }

    [Fact]
    public void Manifest_persists_across_instances()
    {
        var src = CreateSource("foo.c", "int x;");
        var (fn, count) = RecordingCompiler();

        new BuildCache(CacheDir, "sha256:flagsA").GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());

        // Brand-new instance, same flags, same source — should load the
        // existing manifest and hit.
        new BuildCache(CacheDir, "sha256:flagsA").GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());
    }

    [Fact]
    public void Compile_failure_surfaces_error_and_does_not_write_manifest_entry()
    {
        var src = CreateSource("foo.c", "int x;");
        var failing = new BuildCache.CompileFn((s, o) =>
            new BuildCache.CompileResult(false, "stdout", "stderr"));

        var cache = new BuildCache(CacheDir, "sha256:flagsA");
        cache.GetOrCompile("stdlib", src, failing, out var err);

        Assert.NotNull(err);
        Assert.Contains("stderr", err);

        // Next call (with a working compiler) should still be a miss because
        // the failed attempt did not record an entry.
        var (fn, count) = RecordingCompiler();
        cache.GetOrCompile("stdlib", src, fn, out _);
        Assert.Equal(1, count());
    }
}
