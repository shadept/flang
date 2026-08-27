# Self-hosted bootstrapping without a reference compiler

How real self-hosted compilers keep building themselves after the original implementation is
retired, and a concrete scheme for FLang. Everything in the survey sections is sourced; the FLang
numbers were measured in this repo (2026-08-27, `bootstrap/build/` after a self-build).

The problem: once the C# reference compiler is gone, the only thing that can compile the FLang
compiler is a previous FLang compiler. That previous compiler must come from somewhere at every
commit, forever, or the project can no longer be built from a clean clone.

## How established self-hosted compilers do it

### Rust: downloaded beta binaries + `cfg(bootstrap)`

- **stage0** is a prebuilt *beta* compiler that the build system downloads: "the stage0 compiler is
  by default the very recent beta rustc compiler". stage0 compiles the in-tree source to produce
  **stage1**; stage1 rebuilds it (with the in-tree std) to produce **stage2**, "the truly current
  compiler", which is what ships.
  ([rustc-dev-guide, Bootstrapping](https://rustc-dev-guide.rust-lang.org/building/bootstrapping/what-bootstrapping-does.html))
- The pinned seed lives in a checked-in manifest,
  [`src/stage0`](https://github.com/rust-lang/rust/blob/master/src/stage0): dist server
  (`https://static.rust-lang.org`), compiler date/commit, and sha256 hashes for every per-target
  artifact. No binaries in the repo.
- New syntax cannot appear in compiler source until stage0 understands it. The escape hatch is
  conditional compilation: "the build system sets `--cfg bootstrap` when building with stage0, so
  we can use `cfg(not(bootstrap))` to only use features when built with stage1". The stage0 pin is
  bumped each release cycle (master is always buildable by the current beta), after which the
  `cfg(bootstrap)` arms are deleted. So the wait for *unconditional* use of a new feature is one
  release cycle (6 weeks); with `cfg(bootstrap)` gating, zero.

### Go: no seed in the repo, a required prior release

- Go 1.4 was "the last Go release with a compiler written in C"; from 1.5 on the toolchain is
  written in Go and needs a Go compiler to build.
- The requirement ladder: 1.5-1.19 build with Go 1.4 (C), 1.20-1.21 with Go 1.17, 1.22-1.23 with
  Go 1.20, and "Go version 1.N will require a Go 1.M compiler, where M is N-2 rounded down to an
  even number". ([Installing Go from source](https://go.dev/doc/install/source))
- The yearly bump policy is [proposal #54265](https://github.com/golang/go/issues/54265): old
  bootstrap toolchains caused real bugs, so the seed now tracks roughly last year's release.
  Nothing is checked in; you download a binary release, cross-compile from another machine, or
  climb the whole ladder from the Go 1.4 C sources.
- Consequence of the N-2 window: the compiler and std cannot use a language feature until roughly
  two releases after it ships.

### OCaml: compiled artifacts checked into `boot/`, promoted deliberately

- The repo carries `boot/`: "a version of ocamlrun and all the `*.cm*` files of the standard
  library" - i.e. the previous compiler as portable OCaml bytecode, in git.
- Day-to-day builds just use `boot/`. A **bootstrap** (rebuilding `boot/` itself) is needed only
  "when something changes in the runtime system ... or when the format of OCaml compilation object
  files like .cmi files is modified".
- The promotion workflow: build with the current `boot/` (`make coreall`), test, then
  `make bootstrap` copies the newly built compiler into `boot/`. The check before promoting is a
  fixpoint: the new compiler must recompile itself successfully - "we now know the system works
  and can thus build the new boot/ binaries".
  ([ocaml/ocaml BOOTSTRAP.adoc](https://github.com/ocaml/ocaml/blob/trunk/BOOTSTRAP.adoc))

### Zig: a checked-in wasm blob fed through wasm2c

Zig deleted its 80k-line C++ stage1 and replaced it with a binary seed in the repo, chosen after
explicitly rejecting the two obvious alternatives
([Goodbye to the C++ implementation of Zig](https://ziglang.org/news/goodbye-cpp/)):

- **Checked-in generated C** (the compiler compiled to C by its own C backend): the output was
  "an 80 MiB C file" and target-specific. Rejected for size and per-target churn.
- **Prior-release binaries** (the Rust/Go model): rejected for "losing the ability to build any
  commit from source" and for limiting supported hosts to whatever prior binaries exist.
- **What won**: compile the compiler (C-backend only) to wasm32-wasi - the one target that is
  OS-agnostic, pointer-size-fixed, and deterministic - and check in `stage1/zig1.wasm.zst` (637 KB
  compressed). A ~4k-line portable C `wasm2c` translator plus a minimal WASI interpreter (~24
  syscalls) turns it back into C; the system C compiler builds that; the result builds the real
  compiler; a final stage verifies bytewise consistency.
- The blob "only needs to be updated when a breaking change or new feature affects the compiler
  when building itself"; the update is one command, `zig build update-zig1`.

### Others, briefly

- **GHC** follows a two-release boot policy (each release buildable by the two most recent major
  releases); no seed in the repo, you install a prior GHC. Full source bootstrap is famously
  hard - see
  [Breitner, Thoughts on bootstrapping GHC](https://www.joachim-breitner.de/blog/748-Thoughts_on_bootstrapping_GHC).
- **Free Pascal** similarly requires the previous FPC release as the starting compiler.

The field splits cleanly in two: infrastructure-rich projects (Rust, Go, GHC) seed from **released
binaries hosted outside the repo**; projects that value clone-and-build seed from **a checked-in
artifact promoted by hand** (OCaml bytecode, Zig wasm). FLang belongs to the second group.

## Evolving the language when the compiler is written in itself

The iron rule everywhere: **compiler source may only use features the seed compiler already
supports.** A feature's lifecycle is therefore always:

1. Implement the feature in the compiler (the *implementation* may be written using only old
   features).
2. Test it through the harness - the current seed builds a compiler that *accepts* the new feature
   even though its own source does not use it.
3. Advance the seed to a compiler that has the feature.
4. Only now may compiler source use the feature.

The projects differ only in how long step 3 takes:

- Rust: next beta bump (6 weeks), or immediately behind `cfg(bootstrap)` at the cost of writing
  both variants.
- Go: roughly two years (the N-2 policy), accepted deliberately.
- OCaml, Zig: one promote command, so the window can be a single commit.

A small project without release infrastructure should copy OCaml/Zig: promoting the seed is a
cheap, deliberate, in-repo act, so there is no need for `cfg(bootstrap)`-style dual-source gating.
FLang's comptime `#if` could express a bootstrap flag if ever needed, but maintaining two variants
of compiler code is the price big projects pay for *not* controlling their seed cadence. With an
in-repo seed, just promote first and use the feature in the next commit.

## Storing the seed: the three options

| Option | Used by | Pros | Cons |
|---|---|---|---|
| Release archive outside the repo | Rust, Go, GHC | repo stays small; per-target artifacts | needs hosting + release process; clean clone is not self-contained; dead links brick old commits |
| Checked-in binary | OCaml (bytecode), Zig (wasm) | self-contained; small if the format is portable | opaque blob in git; needs an interpreter/translator unless native (and native means one blob per platform) |
| Checked-in generated output (C) | Zig considered and rejected at 80 MiB | self-contained; text (git delta-compresses); auditable-ish; needs only a C compiler | large; target-specific if codegen bakes in the target; must regenerate whenever runtime/ABI changes |

Measured FLang numbers (self-build output in `bootstrap/build/`):

- `flang.c`, the whole compiler as one generated C99 file: **18.1 MB raw, 1.8 MB gzipped**. An
  order of magnitude under Zig's 80 MiB rejection point, and git stores text deltas, so a
  rarely-promoted seed costs a few MB of pack per promote.
- The native executable: 2.9 MB - smaller, but an opaque per-OS binary.
- Runtime sidecars (the stdlib's companion `.c` files): ~55 KB, already plain source in-tree.

One real caveat, the same one Zig hit: FLang's emitted C is **per-target**. Comptime `#if`
(`--target-os` / `--target-arch`) is resolved before lowering, so a seed generated for Windows is
not the seed for Linux. Since the comptime context is overridable at build time, one host can emit
the seed C for every supported OS in one promote; the repo then carries one seed file per OS family
(2-3 files at ~18 MB each, ~2 MB gz each).

For a compiler that already targets C99, checked-in generated C is the natural seed: a clean clone
needs exactly one tool (a C99 compiler) to cold start, there are no binaries in git, and the
artifact is diffable enough to eyeball what a promote changed.

## Trusting trust, briefly

Ken Thompson's
["Reflections on Trusting Trust"](https://dl.acm.org/doi/10.1145/358198.358210) attack: a compiler
binary can carry a self-propagating trojan that inserts itself into every future compiler built
with it, invisibly to source review. David A. Wheeler's
[Diverse Double-Compiling](https://dwheeler.com/trusting-trust/) counters it: compile the
compiler's source with a second, independent trusted compiler, then use that result to compile the
source again; "if the result is bit-for-bit identical with the untrusted executable, then the
source code accurately represents the executable". His dissertation demonstrated it on real
compilers including GCC. [Bootstrappable Builds](https://bootstrappable.org/) generalizes the
concern: "opaque binaries are a threat to user security and user freedom since they are not
auditable", hence the goal of building everything from source.
[mrustc](https://github.com/thepowersgang/mrustc) is the alternative-path example for Rust: an
independent Rust-to-C compiler in C++ that can build old rustc versions, giving a binary-free root
for the whole rustc chain.

How much should a solo passion project care? Almost not at all as a threat model - nobody is
trojaning this seed. But two DDC-shaped habits are free and worth keeping:

- The retired C# compiler, preserved in git history, *is* a diverse second root forever. Anyone
  (including future you) can rebuild the chain from it and compare.
- Before retiring it, record one DDC run: C#-built self-host and seed-built self-host both reach
  the same byte-identical stage-2 C. That is the cross-check Wheeler describes, done once while
  both roots still exist.

## Failure modes and mitigations

- **Bricking the bootstrap.** A miscompiling compiler builds a subtly worse compiler; promote that
  and every later build inherits the defect, with the working ancestor gone. Mitigation: the seed
  is immutable except through an explicit promote step, and promoting requires the full test gate
  (below). Old seeds stay in git history and tags, so even a bad promote is revertible.
- **Fixpoint drift.** The classic sanity check (Zig's final stage, OCaml's self-recompile, FLang's
  existing check): stage-2 and stage-3 outputs must be byte-identical. Nondeterminism or a
  self-miscompile shows up here first. FLang already holds this fixpoint on both Unix and MSVC
  (docs/self-host.md).
- **Seed rot.** HEAD grows until the committed seed can no longer build it, discovered months
  later. Mitigation: CI builds HEAD *from the seed* on every push, not just with yesterday's dev
  binary.
- **Losing cold start.** If any commit requires a binary that no longer exists (deleted release
  asset, wrong-platform blob), that commit is unbuildable forever. Mitigation: the seed lives in
  the repo, so every commit is self-contained by construction; `git bisect` keeps working because
  each commit carries the seed that builds it.
- **Runtime/ABI skew.** Generated seed C calls into runtime sidecars; if HEAD's sidecars drift
  from what the seed C expects, the cold start breaks at link. Mitigation: the promote copies the
  sidecar `.c` files (and any headers) into the seed directory alongside the generated C, so the
  seed is a closed set of files. This is OCaml's trigger list ("something changes in the runtime
  system") turned into a non-event.

## Recommendation for FLang

Copy OCaml's model with Zig's artifact insight, using the C99 backend as the seed format.

1. **`boot/` directory, checked in.** Per supported OS family: `boot/<os>/flang.c` plus the
   runtime sidecar `.c` files it links against, all raw text (no compression - diffability and
   cc-is-the-only-tool beat 16 MB of repo weight). Plus a tiny build script (the existing cc
   invocation) so cold start is `cc boot/<os>/*.c -> flang-seed`.
2. **A `promote` step** (build.cs subcommand or script), the analog of OCaml's `make bootstrap` /
   Zig's `update-zig1`. It refuses unless: stage-2 = stage-3 C is byte-identical, and the full
   harness passes under stage-2. Then it regenerates the seed C for every supported OS via
   `--target-os` and copies it into `boot/`, one commit, tagged `seed/<language-version>` (or
   `seed/<date>`). Tags double as the language-version archive.
3. **The seed rule, written down in CLAUDE.md:** compiler, `lib/*`, and `stdlib` sources may only
   use language features the current `boot/` seed supports. New feature order: implement,
   harness-test, promote, then use. No `cfg(bootstrap)` machinery - with promotion this cheap,
   dual-variant source is pure overhead.
4. **Promote deliberately, not per-commit** (OCaml cadence, Zig's "only when building itself needs
   it"). Typical triggers: about to use a new feature in compiler source, runtime/ABI change, or a
   periodic refresh. Rare promotes keep the 18 MB file from churning the pack.
5. **CI cold-start job:** from a clean checkout, cc the seed, build HEAD with it (stage-1), build
   stage-2, assert stage-2 C == stage-3 C, run the harness with stage-2. This single job covers
   seed rot, fixpoint drift, and the seed rule (a compiler source file using an unsupported
   feature fails at stage-1).
6. **Publish binaries on promote.** Each promote also uploads the native `flang` executable per
   platform to a GitHub release (same tag as the seed). Two consumers: a just-in-case escape hatch
   if a seed ever proves unbuildable, and editor components, which download the LSP server as a
   prebuilt native binary rather than cold-starting from seed C.
7. **Retiring the C# compiler:** before removal, run the one-time DDC-style record (C# path and
   seed path converge on identical stage-2 C) and note the commit hash. Keep the C# source in
   history; optionally attach a final `flang-ref` binary to a git tag or release as a convenience
   escape hatch. After that, `bootstrap/` no longer needs the C# tree at HEAD.

Rejected alternatives, for the record:

- **Release binaries only (Rust/Go model):** wrong fit - no release infrastructure, single
  developer, and it breaks clone-and-build and bisect. Revisit only if the repo ever gains real
  releases.
- **Checked-in native executable:** 2.9 MB but opaque, per-platform, and un-diffable; the C form
  costs more bytes and buys auditability and portability (any C99 compiler, any future machine).
- **Compressed seed (`flang.c.zst`, Zig-style):** saves ~16 MB per OS but reintroduces a binary
  blob and a decompression dependency into cold start. Zig needed compression at 80 MiB; 18 MB
  does not force it.

Open questions to settle when implementing:

- Which OS families get a committed seed (win + linux + mac, or fewer)? Does `--target-arch` also
  change emitted C today, i.e. is the seed per-OS or per-OS-arch?
- Whether `promote` lives in build.cs, a script, or `flang` itself.
- Whether the harness gate for promotion is the full suite or the reference-parity subset.

## Sources

- [rustc-dev-guide: Bootstrapping](https://rustc-dev-guide.rust-lang.org/building/bootstrapping/what-bootstrapping-does.html)
- [rust-lang/rust src/stage0](https://github.com/rust-lang/rust/blob/master/src/stage0)
- [Installing Go from source](https://go.dev/doc/install/source)
- [Go proposal #54265: bootstrap toolchain cadence](https://github.com/golang/go/issues/54265)
- [ocaml/ocaml BOOTSTRAP.adoc](https://github.com/ocaml/ocaml/blob/trunk/BOOTSTRAP.adoc)
- [Zig: Goodbye to the C++ implementation](https://ziglang.org/news/goodbye-cpp/)
- [Wheeler: Countering Trusting Trust through Diverse Double-Compiling](https://dwheeler.com/trusting-trust/)
- [Bootstrappable Builds](https://bootstrappable.org/)
- [mrustc](https://github.com/thepowersgang/mrustc)
- [Breitner: Thoughts on bootstrapping GHC](https://www.joachim-breitner.de/blog/748-Thoughts_on_bootstrapping_GHC)
- FLang: docs/self-host.md (stage-2 = stage-3 fixpoint), docs/architecture.md (build pipeline);
  sizes measured from `bootstrap/build/` in this repo.
