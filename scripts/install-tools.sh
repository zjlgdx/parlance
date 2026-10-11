#!/bin/bash
# Public CI tool pins (versions and sha256), matching the private runner installer; supports Linux and macOS.
# Usage: bash scripts/install-tools.sh [--check]
set -euo pipefail

ACTIONLINT_VERSION=1.7.12
GITLEAKS_VERSION=8.30.1
SHELLCHECK_VERSION=0.11.0

# sha256 per asset: actionlint and gitleaks match their release checksum files; shellcheck publishes none.
case "$(uname -s)/$(uname -m)" in
  Linux/aarch64|Linux/arm64)
    OS=linux AL_ARCH=arm64 GL_ARCH=arm64 SC_ARCH=aarch64
    AL_SHA=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
    GL_SHA=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    SC_SHA=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
  Linux/x86_64|Linux/amd64)
    OS=linux AL_ARCH=amd64 GL_ARCH=x64 SC_ARCH=x86_64
    AL_SHA=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    GL_SHA=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    SC_SHA=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
  Darwin/arm64)
    OS=darwin AL_ARCH=arm64 GL_ARCH=arm64 SC_ARCH=aarch64
    AL_SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    GL_SHA=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    SC_SHA=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
  Darwin/x86_64)
    OS=darwin AL_ARCH=amd64 GL_ARCH=x64 SC_ARCH=x86_64
    AL_SHA=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    GL_SHA=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
    SC_SHA=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
  *) OS= ;;
esac

have() {  # have <tool> <version> [<version flag>]: the tool on PATH reports that version (8.30.1 is not 8.30.10)
  local out
  command -v "$1" >/dev/null 2>&1 || return 1
  out=$("$1" "${3:---version}" 2>&1) || return 1
  grep -Eq "(^|[^0-9.])${2//./\\.}(\$|[^0-9.])" <<<"$out"
}
if [ "${1:-}" = "--check" ]; then
  rc=0
  have actionlint "$ACTIONLINT_VERSION" -version || { echo "missing actionlint $ACTIONLINT_VERSION"; rc=1; }
  have gitleaks "$GITLEAKS_VERSION" version || { echo "missing gitleaks $GITLEAKS_VERSION"; rc=1; }
  have shellcheck "$SHELLCHECK_VERSION" || { echo "missing shellcheck $SHELLCHECK_VERSION"; rc=1; }
  exit $rc
fi
[ -n "$OS" ] || { echo "install-tools: unsupported platform $(uname -s)/$(uname -m)" >&2; exit 2; }

BIN=/usr/local/bin
if [ ! -w "$BIN" ]; then
  BIN="${RUNNER_TEMP:-$HOME/.local}/bin"
  mkdir -p "$BIN"
fi
# macOS runners may put Homebrew before /usr/local/bin; keep these pins first in later steps too.
if [ -n "${GITHUB_PATH:-}" ]; then echo "$BIN" >> "$GITHUB_PATH"; fi
export PATH="$BIN:$PATH"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

fetch() {  # fetch <url> <file> <sha256>: nothing is unpacked unless the download matches its pin
  curl -fsSL --retry 3 -o "$2" "$1"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$3  $2" | sha256sum -c - >/dev/null
  else
    echo "$3  $2" | shasum -a 256 -c - >/dev/null
  fi
}

if ! have actionlint "$ACTIONLINT_VERSION" -version; then
  fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${OS}_${AL_ARCH}.tar.gz" al.tgz "$AL_SHA"
  tar -xzf al.tgz actionlint && install -m 0755 actionlint "$BIN/actionlint"
fi
if ! have gitleaks "$GITLEAKS_VERSION" version; then
  fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_${GL_ARCH}.tar.gz" gl.tgz "$GL_SHA"
  tar -xzf gl.tgz gitleaks && install -m 0755 gitleaks "$BIN/gitleaks"
fi
if ! have shellcheck "$SHELLCHECK_VERSION"; then
  fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${OS}.${SC_ARCH}.tar.xz" sc.txz "$SC_SHA"
  tar -xJf sc.txz && install -m 0755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck"
fi
# A runner's existing tools and newly installed binaries must satisfy the same pins.
have actionlint "$ACTIONLINT_VERSION" -version
have gitleaks "$GITLEAKS_VERSION" version
have shellcheck "$SHELLCHECK_VERSION"
actionlint -version | head -n 1
gitleaks version
shellcheck --version | sed -n 2p
