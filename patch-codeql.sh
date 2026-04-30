#!/usr/bin/env bash
#
# patch-codeql.sh — Patch a CodeQL installation to run on ARM64 Linux
#
# Usage:
#   ./patch-codeql.sh [CODEQL_DIR]
#
# The Java major version is auto-detected from the bundled JDK's release file.
# Override with JAVA_MAJOR=XX environment variable if needed.
#
# This script:
#   1. Detects the bundled JDK version from tools/linux64/java/release
#   2. Downloads a matching ARM64 Temurin JDK
#   3. Places it at tools/linux64/java-aarch64
#   4. Patches the launcher script to use it on aarch64
#
# Prerequisites:
#   - Docker (for QEMU binfmt registration)
#   - curl, tar, python3
#
# For interpreted languages (Python, JS, Ruby, Go, Java, C#):
#   Just this script + docker/setup-qemu-action (or `docker run --privileged
#   tonistiigi/binfmt --install amd64`) is sufficient.
#
# For compiled languages (C/C++):
#   Also download the Ubuntu amd64 rootfs and set QEMU_LD_PREFIX (see below)
#
set -euo pipefail

CODEQL_DIR="${1:-./codeql}"

if [ ! -f "$CODEQL_DIR/codeql" ]; then
  echo "Error: $CODEQL_DIR/codeql not found. Pass the CodeQL dist directory as first argument."
  exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "Warning: Current architecture is $ARCH, not ARM64. Patching anyway for portability."
fi

echo "==> Patching CodeQL at: $CODEQL_DIR"

# --- Step 1: Detect bundled JDK version ---
BUNDLED_VERSION=""
JAVA_MAJOR="${JAVA_MAJOR:-}"

if [ -f "$CODEQL_DIR/tools/linux64/java/release" ]; then
  BUNDLED_VERSION=$(grep "JAVA_VERSION=" "$CODEQL_DIR/tools/linux64/java/release" | cut -d'"' -f2)
  echo "    Bundled JDK version: $BUNDLED_VERSION"
  if [ -z "$JAVA_MAJOR" ]; then
    JAVA_MAJOR=$(echo "$BUNDLED_VERSION" | cut -d'.' -f1)
  fi
else
  echo "    Warning: tools/linux64/java/release not found"
fi

if [ -z "$JAVA_MAJOR" ]; then
  JAVA_MAJOR="21"
  echo "    Could not detect Java version, defaulting to JDK $JAVA_MAJOR"
fi

echo "    Target JDK major version: $JAVA_MAJOR"

# --- Step 2: Download ARM64 JDK ---
echo "==> Downloading ARM64 Temurin JDK ${JAVA_MAJOR}..."

JDK_URL=""
if [ -n "$BUNDLED_VERSION" ]; then
  ADOPTIUM_VER=$(echo "$BUNDLED_VERSION" | sed 's/+/%2B/')
  JDK_URL="https://api.adoptium.net/v3/binary/version/jdk-${ADOPTIUM_VER}/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk"
  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L "$JDK_URL")
  if [ "$HTTP_CODE" != "200" ]; then
    echo "    Exact version $BUNDLED_VERSION not available for ARM64, falling back to latest ${JAVA_MAJOR}.x"
    JDK_URL=""
  else
    echo "    Found exact ARM64 match for $BUNDLED_VERSION"
  fi
fi

if [ -z "$JDK_URL" ]; then
  JDK_URL="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk"
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

curl -sL "$JDK_URL" -o "$TMPDIR/jdk-arm64.tar.gz"
tar xzf "$TMPDIR/jdk-arm64.tar.gz" -C "$TMPDIR"
JDK_EXTRACTED=$(find "$TMPDIR" -maxdepth 1 -type d -name "jdk-*" | head -1)

if [ -z "$JDK_EXTRACTED" ]; then
  echo "Error: Failed to extract ARM64 JDK"
  exit 1
fi

rm -rf "$CODEQL_DIR/tools/linux64/java-aarch64"
mv "$JDK_EXTRACTED" "$CODEQL_DIR/tools/linux64/java-aarch64"
echo "    Installed ARM64 JDK at: $CODEQL_DIR/tools/linux64/java-aarch64"

INSTALLED_VERSION=$("$CODEQL_DIR/tools/linux64/java-aarch64/bin/java" -version 2>&1 | head -1)
echo "    $INSTALLED_VERSION"

# --- Step 3: Patch launcher script ---
echo "==> Patching CodeQL launcher script..."

LAUNCHER="$CODEQL_DIR/codeql"

if grep -q 'linux64.*aarch64.*java-aarch64' "$LAUNCHER"; then
  echo "    Already patched."
else
  python3 - "$LAUNCHER" << 'PYEOF'
import sys

launcher_path = sys.argv[1]
with open(launcher_path, 'r') as f:
    content = f.read()

OLD = '''if [ "$CODEQL_PLATFORM" = "osx64" ] && [ "$arch" = "arm64" ]; then
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java-aarch64}
else
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java}
fi'''

NEW = '''if [ "$CODEQL_PLATFORM" = "osx64" ] && [ "$arch" = "arm64" ]; then
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java-aarch64}
elif [ "$CODEQL_PLATFORM" = "linux64" ] && [ "$arch" = "aarch64" ]; then
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java-aarch64}
else
    : ${CODEQL_JAVA_HOME:=$CODEQL_DIST/tools/$CODEQL_PLATFORM/java}
fi'''

if OLD in content:
    content = content.replace(OLD, NEW)
    with open(launcher_path, 'w') as f:
        f.write(content)
    print("    Launcher patched successfully")
else:
    print("    Could not find expected pattern in launcher.")
    print("    Fallback: export CODEQL_JAVA_HOME=" + launcher_path.rsplit('/', 1)[0] + "/tools/linux64/java-aarch64")
PYEOF
fi

# --- Done ---
echo ""
echo "==> CodeQL patched for ARM64!"
echo ""
echo "    Next steps:"
echo "      export PATH=\"$CODEQL_DIR:\$PATH\""
echo "      codeql --version"
echo ""
echo "    QEMU binfmt setup (if not already done):"
echo "      docker run --privileged --rm tonistiigi/binfmt --install amd64"
echo ""
echo "    For compiled languages (C/C++), also download the x86_64 rootfs:"
echo "      mkdir -p /tmp/x86_64-rootfs"
echo "      curl -sL https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-amd64.tar.gz \\"
echo "        | tar xz -C /tmp/x86_64-rootfs"
echo "      export QEMU_LD_PREFIX=/tmp/x86_64-rootfs"
