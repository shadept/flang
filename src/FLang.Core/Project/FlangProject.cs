namespace FLang.Core.Project;

public record FlangProject(
    ProjectInfo Project,
    BuildSection? Build = null,
    ImportsSection? Imports = null,
    DependenciesSection? Dependencies = null,
    LangSection? Lang = null);

/// <summary>
/// `[lang]` table in flang.toml — per-project language behaviour, the knobs a
/// project opts into rather than the compiler deciding for everyone.
/// </summary>
/// <param name="ImplicitOptionWrap">
/// Whether a bare `T` may be returned or assigned where `Option(T)` is
/// expected, wrapping implicitly. Default true for compatibility; the coercion
/// is on its way out. It interacts badly with generic instantiation — the rule
/// is skipped when the payload is an unbound var, so a `return value` inside a
/// generic function returning `T?` falls through to a structural unify of `T`
/// against `Option(T)` and trips the occurs check. Turning it off makes every
/// such site say `Some(value)` and the failure disappears.
/// </param>
public record LangSection(bool ImplicitOptionWrap = true);

/// Whether a project builds to a linked executable or is consumed by source as a library.
public enum ProjectKind { Exe, Lib }

public record ProjectInfo(
    string Name,
    string Version,
    ProjectKind Kind,
    string Source = "src/**/*.f",
    string Output = "build");

public record PlatformBuildConfig(
    string[]? Headers = null,
    string[]? Libs = null,
    string[]? Cflags = null,
    string[]? Ldflags = null);

public record BuildSection(
    PlatformBuildConfig? Macos = null,
    PlatformBuildConfig? Linux = null,
    PlatformBuildConfig? Windows = null);

/// <summary>
/// `[imports]` table in flang.toml. Values are injected into every project file
/// as implicit private imports — never propagated to stdlib or third-party deps.
/// </summary>
public record ImportsSection(
    string[]? Global = null);

/// <summary>
/// A single entry under `[dependencies]`. Path-based only for now — no registry,
/// no semver, no lockfile. The dep's flang.toml must declare `[project].name`
/// equal to <see cref="Name"/>; its sources must live under
/// `&lt;source_root&gt;/&lt;name&gt;/...` so `import &lt;name&gt;.foo` resolves
/// cleanly across the include-path search.
/// </summary>
public record DependencySpec(string Name, string Path);

/// <summary>
/// `[dependencies]` table in flang.toml. Each entry is path-based and resolved
/// against the consuming project's root at build time.
/// </summary>
public record DependenciesSection(DependencySpec[] Items);
