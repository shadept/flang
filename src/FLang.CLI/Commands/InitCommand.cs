namespace FLang.CLI.Commands;

public static class InitCommand
{
    public static int Run(string[] args)
    {
        var isLib = args.Contains("--lib");
        var name = args.FirstOrDefault(a => !a.StartsWith('-'));
        if (name == null)
        {
            Console.Error.WriteLine("Usage: flang init <name> [--lib]");
            return 1;
        }

        var projectDir = Path.Combine(Directory.GetCurrentDirectory(), name);

        if (Directory.Exists(projectDir) && Directory.GetFileSystemEntries(projectDir).Length > 0)
        {
            Console.Error.WriteLine($"error: directory '{name}' already exists and is not empty");
            return 1;
        }

        Directory.CreateDirectory(projectDir);
        Directory.CreateDirectory(Path.Combine(projectDir, "src"));

        var kind = isLib ? "lib" : "exe";

        // flang.toml
        File.WriteAllText(Path.Combine(projectDir, "flang.toml"),
            $"""
            [project]
            name = "{name}"
            version = "0.1.0"
            kind = "{kind}"

            """);

        // An executable gets a `main`; a library exports a public function instead.
        if (isLib)
            File.WriteAllText(Path.Combine(projectDir, "src", $"{name}.f"),
                $$"""
                // The library's public surface. Consumers `import {{name}}.{{name}}`.
                pub fn hello() String {
                    return "Hello from {{name}}!"
                }

                """);
        else
            File.WriteAllText(Path.Combine(projectDir, "src", "main.f"),
                """
                fn main() {
                    println("Hello, world!")
                }

                """);

        // .gitignore
        File.WriteAllText(Path.Combine(projectDir, ".gitignore"),
            """
            build/
            vendor/
            *.dSYM/
            *.generated.c
            *.generated.f

            """);

        // README.md — toml braces in the dependency snippet fight string
        // interpolation, so assemble these lines by concatenation.
        var usage = isLib
            ? "## Use\n\nAdd to a consumer's `flang.toml`:\n\n```\n[dependencies]\n"
                + name + " = { path = \"../" + name + "\" }\n```\n"
            : "## Run\n\n```\nbuild/" + name + "\n```\n";

        File.WriteAllText(Path.Combine(projectDir, "README.md"),
            $"""
            # {name}

            A FLang {(isLib ? "library" : "project")}.

            ## Build

            ```
            flang build
            ```

            {usage}
            """);

        Console.WriteLine($"Created {kind} project '{name}' in ./{name}/");
        return 0;
    }
}
