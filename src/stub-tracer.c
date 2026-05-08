/*
 * stub-tracer.c — ARM64-native replacement for CodeQL's preload_tracer.
 *
 * CodeQL's preload_tracer is an x86_64 binary that sets up LD_PRELOAD-based
 * build tracing.  On ARM64, QEMU can execute the binary but the x86_64
 * tracer .so cannot be injected into native ARM64 build processes, causing
 * a SIGSEGV (exit 139).
 *
 * This stub replaces the preload_tracer on ARM64 runners so users get a
 * clear diagnostic instead of a cryptic crash.
 *
 * Build (on ARM64 runner):
 *   musl-gcc -static -O2 -s -o preload_tracer src/stub-tracer.c
 *
 * SPDX-License-Identifier: MIT
 *
 * Binary published as a GitHub Release asset by publish-marketplace.yml.
 */

#include <unistd.h>
#include <errno.h>
#include <stddef.h>

int main(void) {
    const char message[] =
        "\n"
        "================================================================\n"
        " codeql-arm64-compat: build tracing is NOT supported on ARM64\n"
        "================================================================\n"
        "\n"
        " The CodeQL preload_tracer uses x86_64 LD_PRELOAD to intercept\n"
        " build system calls.  This cannot work when the build tools are\n"
        " native ARM64 binaries.\n"
        "\n"
        " Workaround: use --build-mode=none (buildless analysis).\n"
        " Buildless mode analyses source code without a build step and\n"
        " is supported for C/C++, Java/Kotlin, C#, and Swift.\n"
        " Go is NOT supported (no --build-mode=none; autobuild needs this tracer).\n"
        "\n"
        "================================================================\n"
        "\n";
    const char *p = message;
    size_t remaining = sizeof(message) - 1;

    while (remaining > 0) {
        ssize_t written = write(STDERR_FILENO, p, remaining);
        if (written > 0) {
            p += (size_t)written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        break;
    }

    return 1;
}
