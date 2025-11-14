### Distribution and publish outputs

Where is the self‑contained executable?

- When you publish FLang.CLI, the .NET publish output is placed at:
  - src/FLang.CLI/bin/<Configuration>/net9.0/<RID>/publish/
  - Example (Windows x64 Release): src/FLang.CLI/bin/Release/net9.0/win-x64/publish/
  - The single self‑contained executable is named FLang.CLI.exe on Windows (no extra runtime needed).

Convenience /dist folder (final, renamed executable + stdlib)

- After publish, the build copies and renames the executable to a stable location with a fixed name, and also places the stdlib folder next to it:
  - Executable: <repo>/dist/<RID>/flang.exe
  - Standard library: <repo>/dist/<RID>/stdlib/**/* (mirrors repo stdlib contents)
  - Example: dist/win-x64/flang.exe and dist/win-x64/stdlib/
  - Both Debug and Release publish to the same destination and overwrite the files.

How to publish

- Default (Windows x64, self‑contained, single file):
  - dotnet publish src/FLang.CLI/FLang.CLI.csproj -c Release
- For a different platform/architecture, override the RID:
  - Linux x64: dotnet publish src/FLang.CLI/FLang.CLI.csproj -c Release -r linux-x64
  - macOS arm64: dotnet publish src/FLang.CLI/FLang.CLI.csproj -c Release -r osx-arm64

Notes

- Pass `--release` to the `flang` CLI when you want the generated C compilation to use the platform optimizer flags (`-O2` for GCC/Clang, `/O2` for MSVC).
- The /dist folder contains the final executable (flang.exe) and the stdlib folder. PDBs are not copied there.
- Trimming is disabled by default to avoid potential reflection issues. You can experiment with -p:PublishTrimmed=true if needed.
