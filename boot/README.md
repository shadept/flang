# boot/ - the bootstrap seed

The self-hosted compiler as generated C99, one directory per target, plus the
stdlib's hand-written runtime sidecar `.c` files it links against. This is
what a clean clone cold-starts from: building a seed needs a C compiler and
nothing else - no prior FLang binary.

Cold start:

    cd boot/<target>
    make                          # linux-x64, darwin-arm64
    build.bat                     # win-x64, from a VS developer prompt

That produces `flang-seed`, a full FLang compiler. It then builds the current
sources (stage 1), which build themselves again (stage 2):

    cd ../../compiler
    ../boot/<target>/flang-seed build -r -s ../stdlib     # stage 1
    build/flang build -r -s ../stdlib                     # stage 2

`boot/SEED` records the compiler version, commit, and date the seed was
emitted from.

Never edit these files by hand: the only writer is `dotnet run promote.cs`.
The seed rule, promote gates, and CI coverage are documented in
`docs/architecture.md` (Bootstrap Seed).
