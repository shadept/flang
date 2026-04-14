namespace FLang.Core.Project;

public record FlangProject(
    ProjectInfo Project,
    BuildSection? Build = null);

public record ProjectInfo(
    string Name,
    string Version,
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
