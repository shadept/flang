namespace FLang.CLI.Commands;

public static class InitCommand
{
    public static int Run(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: flang init <name>");
            return 1;
        }

        var name = args[0];
        var projectDir = Path.Combine(Directory.GetCurrentDirectory(), name);

        if (Directory.Exists(projectDir) && Directory.GetFileSystemEntries(projectDir).Length > 0)
        {
            Console.Error.WriteLine($"error: directory '{name}' already exists and is not empty");
            return 1;
        }

        Directory.CreateDirectory(projectDir);
        Directory.CreateDirectory(Path.Combine(projectDir, "src"));

        // flang.toml
        File.WriteAllText(Path.Combine(projectDir, "flang.toml"),
            $"""
            [project]
            name = "{name}"
            version = "0.1.0"

            """);

        // src/main.f
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

        // README.md
        File.WriteAllText(Path.Combine(projectDir, "README.md"),
            $"""
            # {name}

            A FLang project.

            ## Build

            ```
            flang build
            ```

            ## Run

            ```
            build/{name}
            ```

            """);

        Console.WriteLine($"Created project '{name}' in ./{name}/");
        return 0;
    }
}
