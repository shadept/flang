using System.Security.Cryptography;
using System.Text;
using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend;

public record ModuleCacheEntry(
    ModuleNode Module,
    IReadOnlyList<Diagnostic> ParseDiagnostics,
    string ContentHash);

public class CompilationCache
{
    private readonly Dictionary<string, ModuleCacheEntry> _modules = [];

    public ModuleCacheEntry? GetCachedModule(string filePath, string contentHash)
    {
        if (_modules.TryGetValue(filePath, out var entry) && entry.ContentHash == contentHash)
            return entry;
        return null;
    }

    public void StoreModule(string filePath, ModuleCacheEntry entry)
    {
        _modules[filePath] = entry;
    }

    public void InvalidateModule(string filePath)
    {
        _modules.Remove(filePath);
    }

    public void InvalidateAll()
    {
        _modules.Clear();
    }

    public static string ComputeHash(string content)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(content));
        return Convert.ToHexString(bytes);
    }
}
