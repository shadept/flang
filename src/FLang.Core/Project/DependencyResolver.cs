namespace FLang.Core.Project;

/// <summary>
/// A resolved dependency: its declared name, its loaded project metadata, and
/// the absolute path to its source root (the directory to append to the
/// consuming compilation's include paths).
/// </summary>
public record ResolvedDependency(
    string Name,
    string ProjectRoot,
    string SourceRoot,
    FlangProject Project);

public static class DependencyResolver
{
    /// <summary>
    /// Resolve every direct dependency declared in <paramref name="project"/>.
    /// Path-only, flat (no transitive deps yet). Throws on missing flang.toml,
    /// missing source root, or name/key mismatch — these are configuration
    /// errors callers should surface directly to the user.
    /// </summary>
    public static List<ResolvedDependency> ResolveDirect(FlangProject project, string projectRoot)
    {
        var result = new List<ResolvedDependency>();
        if (project.Dependencies == null) return result;

        foreach (var dep in project.Dependencies.Items)
        {
            var depRoot = Path.IsPathRooted(dep.Path)
                ? dep.Path
                : Path.GetFullPath(Path.Combine(projectRoot, dep.Path));

            var depTomlPath = Path.Combine(depRoot, ProjectLoader.ProjectFileName);
            if (!File.Exists(depTomlPath))
                throw new InvalidOperationException(
                    $"dependency '{dep.Name}': no flang.toml at {depRoot}");

            FlangProject depProject;
            try { depProject = ProjectLoader.Load(depTomlPath); }
            catch (Exception ex)
            {
                throw new InvalidOperationException(
                    $"dependency '{dep.Name}': failed to load {depTomlPath}: {ex.Message}");
            }

            if (depProject.Project.Name != dep.Name)
                throw new InvalidOperationException(
                    $"dependency '{dep.Name}': flang.toml declares [project].name = "
                    + $"'{depProject.Project.Name}', expected '{dep.Name}'");

            var sourceRoot = ProjectLoader.ResolveSourceRoot(depProject.Project.Source, depRoot);
            if (sourceRoot == null)
                throw new InvalidOperationException(
                    $"dependency '{dep.Name}': source root not found "
                    + $"(glob '{depProject.Project.Source}' under {depRoot})");

            // The dep's `[project].name` IS its import namespace. Files directly
            // under the source root are imported as `<name>.<file>`. No nested
            // `<source_root>/<name>/` folder — that would mean `<name>.<name>.foo`.

            result.Add(new ResolvedDependency(dep.Name, depRoot, sourceRoot, depProject));
        }

        return result;
    }
}
