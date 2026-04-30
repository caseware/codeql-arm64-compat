# CodeQL on ARM64 — GitHub Action

Run [CodeQL](https://github.com/github/codeql) analysis on **ARM64 Linux** runners (GitHub-hosted `ubuntu-24.04-arm` or self-hosted `aarch64`) by transparently emulating x86_64 native binaries via QEMU user-mode and swapping the bundled JDK for an ARM64 build.

## Background

CodeQL is distributed as x86_64-only for Linux ([github/codeql#16692](https://github.com/github/codeql/issues/16692), [github/codeql-cli-binaries#97](https://github.com/github/codeql-cli-binaries/issues/97), [github/codeql#20616](https://github.com/github/codeql/issues/20616)).

This action works around the limitation with two techniques:

1. **ARM64 JDK** — The CodeQL evaluation engine is pure Java (`tools/codeql.jar`). We replace the bundled x86_64 JDK with a matching ARM64 Temurin build so queries execute **natively** at full speed.
2. **QEMU user-mode via `docker/setup-qemu-action`** — Registers `qemu-x86_64-static` as the kernel's `binfmt_misc` interpreter for x86_64 ELF binaries. Any remaining native x86_64 binaries (extractors, `runner`, tracer `.so` libs) execute transparently.

For **compiled languages** (C/C++) that require dynamically-linked x86_64 tracer binaries, the action optionally extracts an x86_64 rootfs from a Docker image and sets `QEMU_LD_PREFIX` so the dynamic linker resolves correctly — no `apt`, no `dpkg --add-architecture`, no root.

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

### Compiled languages (C/C++)

```yaml
      - uses: your-org/codeql-arm64-action@v1
        with:
          enable-compiled-languages: 'true'
```

This extracts an x86_64 rootfs from a Docker image and sets `QEMU_LD_PREFIX` so the dynamically-linked tracer binaries (`preload_tracer`, `runner`) can resolve glibc under QEMU. Not needed for interpreted languages.

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
| `enable-compiled-languages` | `false` | Extract x86_64 rootfs and set `QEMU_LD_PREFIX` for C/C++ tracer binaries |

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
│                              │ x86_64 rootfs (Docker)     │ │
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

1. `docker create --platform linux/amd64 ubuntu:22.04` — create a throwaway container
2. `docker export` — extract its `/lib`, `/lib64`, and `/usr/lib` directories
3. Set `QEMU_LD_PREFIX` — tells `qemu-user` where to find the x86_64 dynamic linker and shared libraries

No apt, no dpkg, no root required for package management.

### Why interpreted languages don't need the rootfs

For Python, JavaScript, Ruby, Go, Java, and C#, the CodeQL extractors are Java-based — they parse source files directly using the evaluation engine (which runs natively via the ARM64 JDK). No x86_64 native binary is invoked during extraction or analysis.

## Compatibility

| Runner | Status |
|--------|--------|
| `ubuntu-24.04-arm` (GitHub-hosted) | Supported |
| `ubuntu-22.04-arm` (GitHub-hosted) | Supported |
| Self-hosted ARM64 (Ubuntu 22.04+) | Supported |
| macOS ARM64 | Not needed (CodeQL has native macOS ARM64 support) |

## Languages tested

| Language | Database creation | Analysis | `enable-compiled-languages` needed? |
|----------|------------------|----------|--------------------------------------|
| Python | Yes | Yes | No |
| JavaScript/TypeScript | Yes | Yes | No |
| Ruby | Yes | Yes | No |
| Go | Yes | Yes | No |
| Java | Yes | Yes | No |
| C/C++ | Yes* | Yes | **Yes** |
| C# | Yes* | Yes | **Yes** |

*\* Compiled language extraction requires `enable-compiled-languages: 'true'` for the x86_64 tracer binaries.*

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
CID=$(docker create --platform linux/amd64 ubuntu:22.04 /bin/true)
docker export $CID | tar -x -C /tmp/x86_64-rootfs --include='lib/*' --include='lib64/*' --include='usr/lib/*'
docker rm $CID
export QEMU_LD_PREFIX=/tmp/x86_64-rootfs
```

## Contributing

Issues and PRs welcome. Key areas for improvement:
- [ ] Cached ARM64 JDK downloads via `actions/cache`
- [ ] Performance benchmarks vs native x86_64
- [ ] Testing matrix across CodeQL versions
- [ ] Auto-detection of compiled vs interpreted language to skip rootfs when not needed

## License

MIT
