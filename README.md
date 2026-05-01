# CodeQL on ARM64 — GitHub Action

Run [CodeQL](https://github.com/github/codeql) analysis on **ARM64 Linux** runners (GitHub-hosted `ubuntu-24.04-arm` or self-hosted `aarch64`) by transparently emulating x86_64 native binaries via QEMU user-mode and swapping the bundled JDK for an ARM64 build.

## Background

CodeQL is distributed as x86_64-only for Linux ([github/codeql#16692](https://github.com/github/codeql/issues/16692), [github/codeql-cli-binaries#97](https://github.com/github/codeql-cli-binaries/issues/97), [github/codeql#20616](https://github.com/github/codeql/issues/20616)).

This action works around the limitation with two techniques:

1. **ARM64 JDK** — The CodeQL evaluation engine is pure Java (`tools/codeql.jar`). We replace the bundled x86_64 JDK with a matching ARM64 Temurin build so queries execute **natively** at full speed.
2. **QEMU user-mode via `docker/setup-qemu-action`** — Registers `qemu-x86_64-static` as the kernel's `binfmt_misc` interpreter for x86_64 ELF binaries. Any remaining native x86_64 binaries (extractors, `runner`, tracer `.so` libs) execute transparently.

For **compiled languages** (C/C++) that require dynamically-linked x86_64 tracer binaries, the action optionally downloads an official Ubuntu 22.04 amd64 base tarball (~30 MB) and sets `QEMU_LD_PREFIX` so the dynamic linker resolves correctly — no `apt`, no `dpkg --add-architecture`, no root.

### Performance characteristics

| Component | Execution mode | Relative speed |
|-----------|---------------|----------------|
| Query evaluation (Java) | Native ARM64 | ~100% |
| Database finalization (Java) | Native ARM64 | ~100% |
| Source extraction (interpreted langs) | Native ARM64 | ~100% |
| Source extraction (compiled langs) | QEMU user-mode | ~30-70% |

For interpreted languages, the entire pipeline runs natively. Only compiled-language extraction takes a QEMU hit.

## Usage

### Basic — interpreted languages (Python, JS, Ruby, Go, Java, C#)

```yaml
jobs:
  codeql:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4

      - uses: your-org/codeql-arm64-action@v1

      - name: Create database
        run: codeql database create ./codeql-db --language=python --source-root=.

      - name: Run analysis
        run: |
          codeql pack download codeql/python-queries
          codeql database analyze ./codeql-db codeql/python-queries \
            --format=sarif-latest --output=results.sarif

      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
```

### Compiled languages — buildless on ARM64

Build tracing does not work on ARM64 (see [Known limitations](#why-traced-builds-dont-work-on-arm64)).
Use `--build-mode=none` for buildless analysis:

```yaml
jobs:
  codeql:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4

      - uses: your-org/codeql-arm64-action@v1
        with:
          enable-compiled-languages: 'true'

      - name: Create database (buildless)
        run: |
          codeql database create ./codeql-db \
            --language=java \
            --source-root=. \
            --build-mode=none

      - name: Run analysis
        run: |
          codeql database analyze ./codeql-db codeql/java-queries \
            --format=sarif-latest --output=results.sarif --download
```

Supported for Java/Kotlin, C/C++, C#, and Swift. **Not** supported for Go (requires x86_64 runner).

### With `github/codeql-action` (init/analyze pattern)

```yaml
jobs:
  codeql:
    runs-on: ubuntu-24.04-arm
    permissions:
      security-events: write
    steps:
      - uses: actions/checkout@v4

      # Patch CodeQL for ARM64 BEFORE codeql-action/init
      - uses: your-org/codeql-arm64-action@v1
        id: codeql-arm64

      - uses: github/codeql-action/init@v3
        with:
          languages: python
          tools: ${{ steps.codeql-arm64.outputs.codeql-path }}

      - uses: github/codeql-action/analyze@v3
```

### Pin to specific CodeQL version

```yaml
      - uses: your-org/codeql-arm64-action@v1
        with:
          codeql-version: 'v2.25.2'
```

The JDK version is auto-detected from `tools/linux64/java/release`. Override only if necessary:

```yaml
      - uses: your-org/codeql-arm64-action@v1
        with:
          java-version: '21'  # Normally auto-detected
```

### Patch an existing CodeQL installation

```yaml
      - uses: github/codeql-action/init@v3
        id: codeql-init
        with:
          languages: javascript

      - uses: your-org/codeql-arm64-action@v1
        with:
          codeql-path: ${{ steps.codeql-init.outputs.codeql-path }}
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `codeql-version` | `latest` | CodeQL CLI release tag (e.g., `v2.25.2`) |
| `java-version` | _(auto-detected)_ | Temurin JDK major version override (read from bundled JDK) |
| `codeql-path` | _(empty)_ | Existing CodeQL path to patch in place |
| `enable-compiled-languages` | `false` | Download Ubuntu amd64 rootfs and set `QEMU_LD_PREFIX` for C/C++ tracer binaries |

## Outputs

| Output | Description |
|--------|-------------|
| `codeql-path` | Path to the patched CodeQL installation |
| `codeql-version` | Installed CodeQL version tag |

## How it works

### Architecture diagram

```
┌─────────────────────────────────────────────────────────────┐
│  ARM64 Runner                                               │
│                                                             │
│  ┌──────────────────────┐    ┌────────────────────────────┐ │
│  │ codeql (shell script)│───▶│ ARM64 JDK (Temurin)       │ │
│  │                      │    │ → codeql.jar (eval engine) │ │
│  └──────────┬───────────┘    └────────────────────────────┘ │
│             │                                               │
│             │ execve() on x86_64 ELF                        │
│             ▼                                               │
│  ┌──────────────────────┐    ┌────────────────────────────┐ │
│  │ binfmt_misc (kernel) │───▶│ qemu-x86_64-static        │ │
│  │                      │    │ (from docker/setup-qemu)   │ │
│  └──────────────────────┘    └─────────────┬──────────────┘ │
│                                            │                │
│                              ┌─────────────▼──────────────┐ │
│                              │ x86_64 rootfs (Ubuntu)     │ │
│                              │ QEMU_LD_PREFIX=/tmp/rootfs  │ │
│                              │ (only for compiled langs)   │ │
│                              └────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### The CodeQL launcher script

The `codeql` shell script already has ARM64 JDK detection for macOS:

```sh
if [ "$CODEQL_PLATFORM" = "osx64" ] && [ "$arch" = "arm64" ]; then
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java-aarch64}
```

We add the equivalent for Linux:

```sh
elif [ "$CODEQL_PLATFORM" = "linux64" ] && [ "$arch" = "aarch64" ]; then
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java-aarch64}
```

### QEMU setup via Docker

Instead of manually installing `qemu-user-static` via apt, we use [`docker/setup-qemu-action`](https://github.com/docker/setup-qemu-action) which:
- Pulls `tonistiigi/binfmt` (contains statically-linked `qemu-*-static` binaries)
- Registers them with the kernel's `binfmt_misc` facility
- Uses the `F` (fix-binary) flag so the interpreter works across namespaces

### x86_64 rootfs for compiled languages

For compiled-language scanning (C/C++), the CodeQL tracer binaries are dynamically linked against glibc. Rather than installing `libc6:amd64` via apt, we:

1. Download the [official Ubuntu 22.04 amd64 base tarball](https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/) (~30 MB)
2. Extract it to a temporary directory
3. Set `QEMU_LD_PREFIX` — tells `qemu-user` where to find the x86_64 dynamic linker and shared libraries

No apt, no dpkg, no Docker required for the rootfs. Only Docker is needed for the QEMU binfmt registration (`docker/setup-qemu-action`).

### Why interpreted languages don't need the rootfs

For Python, JavaScript, Ruby, Go, Java, and C#, the CodeQL extractors are Java-based — they parse source files directly using the evaluation engine (which runs natively via the ARM64 JDK). No x86_64 native binary is invoked during extraction or analysis.

## Compatibility

| Runner | Status |
|--------|--------|
| `ubuntu-24.04-arm` (GitHub-hosted) | Supported |
| `ubuntu-22.04-arm` (GitHub-hosted) | Supported |
| Self-hosted ARM64 (Ubuntu 22.04+) | Supported |
| `ubuntu-latest` (x86_64) | Pass-through (downloads CodeQL, skips ARM64 patches) |
| macOS ARM64 | Not needed (CodeQL has native macOS ARM64 support) |

## Language support matrix

### Interpreted languages — full ARM64 support

| Language | ARM64 status | SARIF identical to x86_64? | `enable-compiled-languages` needed? |
|----------|:---:|:---:|:---:|
| Python | **Full** | Yes | No |
| JavaScript/TypeScript | **Full** | Yes | No |
| Ruby | **Full** | Yes | Yes* |

These languages use Java-based extractors that run natively via the ARM64 JDK.
SARIF output is identical between ARM64 and x86_64 runners.

\* Ruby's extractor has native x86_64 binaries that need the x86_64 libs for QEMU.

### Compiled languages — buildless mode on ARM64

| Language | ARM64 status | Build mode on ARM64 | `enable-compiled-languages` needed? | Notes |
|----------|:---:|:---:|:---:|-------|
| Java/Kotlin | **Buildless** | `--build-mode=none` | Yes | Analyses source without building |
| C/C++ | **Buildless** | `--build-mode=none` | Yes | Analyses source without building |
| Rust | **Experimental** | `--build-mode=none` | Yes | CodeQL Rust support is experimental |
| Go | **x86_64 only** | Not supported | — | Go does not support `--build-mode=none` |
| C# | **Buildless** | `--build-mode=none` | Yes | Not yet tested |

#### Why traced builds don't work on ARM64

CodeQL's `preload_tracer` is an x86_64 binary that uses `LD_PRELOAD` to inject an x86_64
shared library into build processes to intercept filesystem calls. On ARM64 runners the build
tools (gcc, javac, go build, etc.) are native ARM64 binaries — you cannot inject an x86_64
`.so` into an ARM64 process. The tracer crashes with SIGSEGV (exit code 139).

This action replaces the `preload_tracer` with a native ARM64 stub (`src/stub-tracer.c`) that
prints a clear diagnostic and exits 1, instead of the cryptic SIGSEGV crash. If you
accidentally attempt a traced build on ARM64, you'll see:

```
================================================================
 codeql-arm64-compat: build tracing is NOT supported on ARM64
================================================================

 Workaround: use --build-mode=none (buildless analysis).
================================================================
```

#### Buildless analysis trade-offs

`--build-mode=none` analyses source code without a build step. Trade-offs:

| Aspect | Traced (x86_64) | Buildless (ARM64) |
|--------|:---:|:---:|
| Interprocedural data flow | Full | Reduced |
| Call graph resolution | Full | Heuristic |
| Build-time type resolution | Full | Partial |
| Source-level pattern queries | Full | Full |
| Security queries (OWASP) | Full | Most |

For security scanning, buildless mode catches the majority of findings. The primary gap is
in interprocedural data-flow analysis that depends on build-time type resolution.

## Troubleshooting

### "exec format error" on x86_64 binaries

binfmt_misc is not registered. The action uses `docker/setup-qemu-action` which requires Docker to be available on the runner. Ensure Docker is installed, or for self-hosted runners run:
```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
```

### "Could not open '/lib64/ld-linux-x86-64.so.2'"

The x86_64 dynamic linker is missing. This happens when scanning compiled languages without `enable-compiled-languages: 'true'`. Add:
```yaml
- uses: your-org/codeql-arm64-action@v1
  with:
    enable-compiled-languages: 'true'
```

### JDK version mismatch warnings

The action auto-detects the JDK version from `tools/linux64/java/release`. If auto-detection fails, override with:
```yaml
- uses: your-org/codeql-arm64-action@v1
  with:
    java-version: '21'
```

## Standalone script

For use outside GitHub Actions (CI systems, local dev):

```bash
# Register binfmt for x86_64
docker run --privileged --rm tonistiigi/binfmt --install amd64

# Patch CodeQL
./patch-codeql.sh /path/to/codeql

# For compiled languages, also set up the rootfs:
mkdir -p /tmp/x86_64-rootfs
curl -sL https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-amd64.tar.gz \
  | tar xz -C /tmp/x86_64-rootfs
export QEMU_LD_PREFIX=/tmp/x86_64-rootfs
```

## Contributing

Issues and PRs welcome. Key areas for improvement:
- [ ] Testing matrix across CodeQL versions
- [ ] Native ARM64 CodeQL extractors when GitHub ships them
- [ ] Pre-built stub-tracer release assets (currently compiled at action time)
- [ ] Go ARM64 support (blocked on CodeQL adding `--build-mode=none` for Go)

## License

This action's source code (action.yml, patch-codeql.sh, documentation) is released under the [MIT License](LICENSE).

### Third-party components (fetched at runtime, not redistributed)

| Component | License | How it's used |
|-----------|---------|---------------|
| [GitHub CodeQL CLI](https://github.com/github/codeql-cli-binaries) | [GitHub CodeQL Terms](https://github.com/github/codeql-cli-binaries/blob/main/LICENSE.md) | Downloaded at runtime from GitHub Releases. Free for open-source repos and GitHub Advanced Security customers. Not redistributed by this action. |
| [Eclipse Temurin JDK](https://adoptium.net/) | [GPLv2 + Classpath Exception](https://openjdk.org/legal/gplv2+ce.html) | ARM64 JDK downloaded at runtime from the Adoptium API. Not redistributed. |
| [Ubuntu base tarball](https://cdimage.ubuntu.com/ubuntu-base/) | Various (GPL, LGPL for glibc/coreutils) | amd64 rootfs downloaded at runtime when `enable-compiled-languages: 'true'`. Provides dynamic linker and shared libraries for QEMU. Not redistributed. |
| [tonistiigi/binfmt](https://github.com/tonistiigi/binfmt) (via `docker/setup-qemu-action`) | MIT | QEMU static binaries registered with binfmt_misc. Pulled by Docker at runtime. Not redistributed. |

Users are responsible for ensuring their use of CodeQL complies with [GitHub's CodeQL Terms and Conditions](https://github.com/github/codeql-cli-binaries/blob/main/LICENSE.md).
