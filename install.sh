#!/usr/bin/env bash
# Install ourocode from either a release tarball directory or a source checkout.
set -euo pipefail

# Last-resort fallback, used only when there is no OUROCODE_VERSION override, no
# source checkout to read mix.exs from, and the GitHub latest-release lookup
# fails. Keep this on the newest *stable* tag: pre-releases (0.1.15-beta-N) are
# published as GitHub pre-releases and are excluded from /releases/latest on
# purpose, so pinning one here would push beta bits to users who hit this path.
OUROCODE_DEFAULT_VERSION="0.1.14"
INSTALL_ROOT="${OUROCODE_INSTALL_ROOT:-$HOME/.local/ourocode}"
BIN_DIR="${OUROCODE_BIN_DIR:-$HOME/.local/bin}"
REPO="${OUROCODE_REPO:-Ouro-labs/ourocode}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DOWNLOAD_TMP=""
CUA_TMP=""

cleanup() {
  if [ -n "$DOWNLOAD_TMP" ] && [ -d "$DOWNLOAD_TMP" ]; then
    rm -rf "$DOWNLOAD_TMP"
  fi
  if [ -n "$CUA_TMP" ] && [ -d "$CUA_TMP" ]; then
    rm -rf "$CUA_TMP"
  fi
}
trap cleanup EXIT

platform_name() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    *)
      echo "error: unsupported OS: $os" >&2
      exit 1
      ;;
  esac

  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *)
      echo "error: unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  printf '%s-%s' "$os" "$arch"
}

download_release() {
  local platform name url archive

  if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl not found; install curl or download a release tarball manually." >&2
    exit 1
  fi

  if ! command -v tar >/dev/null 2>&1; then
    echo "error: tar not found; install tar or download a release tarball manually." >&2
    exit 1
  fi

  platform="$(platform_name)"
  name="ourocode-v${VERSION}-${platform}"
  url="${OUROCODE_RELEASE_URL:-https://github.com/${REPO}/releases/download/v${VERSION}/${name}.tar.gz}"

  DOWNLOAD_TMP="$(mktemp -d)"
  archive="$DOWNLOAD_TMP/${name}.tar.gz"

  echo "==> downloading release $name"
  if ! curl -fL "$url" -o "$archive"; then
    missing_release_asset "$platform" "$name" "$url"
    return 1
  fi
  tar -xzf "$archive" -C "$DOWNLOAD_TMP"

  ROOT="$DOWNLOAD_TMP/$name"
  if [ ! -x "$ROOT/ourocode" ] || [ ! -x "$ROOT/bin/ourocode_tty" ]; then
    echo "error: release archive did not contain expected ourocode binaries." >&2
    exit 1
  fi
}

resolve_version() {
  # Resolve the ourocode version without drift: 1) explicit override,
  # 2) unpacked release directory name, 3) source checkout mix.exs,
  # 4) latest release tag, 5) pinned fallback.
  if [ -n "${OUROCODE_VERSION:-}" ]; then
    printf '%s' "$OUROCODE_VERSION"
    return 0
  fi

  # Unpacked release tarball: ourocode-v<version>-<os>-<arch> names the exact
  # build sitting next to this script, so it wins over any remote lookup —
  # otherwise a release install lands in a directory named for whatever the
  # fallback happens to be. Mirrors Get-VersionFromZipName in install.ps1.
  local dir_name
  dir_name="$(basename "$ROOT")"
  if [[ "$dir_name" =~ ^ourocode-v(.+)-(linux|darwin)-(x86_64|arm64)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [ -f "$ROOT/mix.exs" ]; then
    local v
    v="$(grep -E 'version: "' "$ROOT/mix.exs" | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/' || true)"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/' || true)"
    if [ -n "$tag" ]; then
      printf '%s' "$tag"
      return 0
    fi
    echo "warning: could not resolve latest release tag from GitHub; using pinned v${OUROCODE_DEFAULT_VERSION}" >&2
  fi

  printf '%s' "$OUROCODE_DEFAULT_VERSION"
}

missing_release_asset() {
  local platform="$1" name="$2" url="$3"
  {
    echo ""
    echo "error: no prebuilt ourocode release asset for your platform ($platform)."
    echo "       looked for: ${name}.tar.gz"
    echo "       url:        $url"
    echo ""
    echo "  Try one of:"
    echo "   - Point at the repo that publishes releases:"
    echo "       OUROCODE_REPO=<owner>/<repo> ..."
    echo "   - Point at a direct tarball URL:"
    echo "       OUROCODE_RELEASE_URL=<url-to-.tar.gz> ..."
    echo "   - Pin a known-good version:"
    echo "       OUROCODE_VERSION=<x.y.z> ..."
    echo "   - Build from source instead (needs Elixir + Rust):"
    echo "       OUROCODE_BUILD_FROM_SOURCE=1 ..."
    echo ""
  } >&2
}

fetch_source_checkout() {
  # Fetch a source tree so an OUROCODE_BUILD_FROM_SOURCE=1 pipe install can build.
  if ! command -v git >/dev/null 2>&1; then
    echo "error: OUROCODE_BUILD_FROM_SOURCE=1 needs git to fetch source for a pipe install." >&2
    exit 1
  fi

  DOWNLOAD_TMP="${DOWNLOAD_TMP:-$(mktemp -d)}"
  local src="$DOWNLOAD_TMP/src"

  echo "==> fetching source (v$VERSION) to build from source"
  if ! git clone --depth 1 --branch "v$VERSION" "https://github.com/${REPO}.git" "$src" 2>/dev/null; then
    echo "    tag v$VERSION not found; cloning default branch" >&2
    git clone --depth 1 "https://github.com/${REPO}.git" "$src"
  fi

  ROOT="$src"
}

ensure_erlang_runtime() {
  # The bundled `ourocode` is an Erlang escript and needs the Erlang/OTP runtime
  # (`escript`/`erl`) on PATH to run. Release tarballs do not bundle the runtime,
  # so a fresh machine ends up with a working launcher that cannot start. Make
  # the runtime present here (best effort, like the Ouroboros step) so the
  # documented `ourocode` quick start works after install.
  if command -v escript >/dev/null 2>&1; then
    return 0
  fi

  if [ "${OUROCODE_SKIP_ERLANG:-0}" = "1" ]; then
    echo "==> skipping Erlang runtime check (OUROCODE_SKIP_ERLANG=1)" >&2
    return 0
  fi

  echo "==> Erlang runtime (escript) not found; ourocode needs it to run"

  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  if command -v brew >/dev/null 2>&1; then
    echo "    installing Erlang via Homebrew (best effort)"
    if brew install erlang; then
      brew link --overwrite erlang >/dev/null 2>&1 || true
    fi
  elif [ "$os" = "linux" ] && command -v apt-get >/dev/null 2>&1; then
    echo "    installing Erlang via apt-get (best effort; may require sudo)"
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y erlang >/dev/null 2>&1 || true
  elif [ "$os" = "linux" ] && command -v dnf >/dev/null 2>&1; then
    echo "    installing Erlang via dnf (best effort; may require sudo)"
    sudo dnf install -y erlang >/dev/null 2>&1 || true
  fi

  if ! command -v escript >/dev/null 2>&1; then
    echo "" >&2
    echo "error: Erlang/OTP runtime not found and could not be installed automatically." >&2
    echo "       ourocode is an Erlang escript and needs 'escript'/'erl' on PATH." >&2
    echo "       Install Erlang, then re-run this installer:" >&2
    echo "         macOS:         brew install erlang" >&2
    echo "         Debian/Ubuntu: sudo apt-get install erlang" >&2
    echo "         Fedora:        sudo dnf install erlang" >&2
    echo "       Other platforms: https://www.erlang.org/downloads" >&2
    echo "       (set OUROCODE_SKIP_ERLANG=1 to bypass this check)" >&2
    exit 1
  fi
}

VERSION="$(resolve_version)"
INSTALL_DIR="${OUROCODE_INSTALL_DIR:-$INSTALL_ROOT/$VERSION}"
echo "==> ourocode version: v$VERSION (repo: $REPO)"

echo "==> ourocode install"

need_build=0
if [ ! -x "$ROOT/ourocode" ] || [ ! -x "$ROOT/bin/ourocode_tty" ]; then
  need_build=1
fi

if [ "${OUROCODE_BUILD_FROM_SOURCE:-0}" = "1" ]; then
  need_build=1
fi

if [ "$need_build" = "1" ]; then
  if [ "${OUROCODE_BUILD_FROM_SOURCE:-0}" != "1" ]; then
    if [ ! -f "$ROOT/mix.exs" ]; then
      if download_release; then
        need_build=0
      else
        exit 1
      fi
    fi
  elif [ ! -f "$ROOT/mix.exs" ]; then
    fetch_source_checkout
  fi
fi

if [ "$need_build" = "1" ]; then
  echo "==> release binaries not found; building from source"

  if ! command -v mix >/dev/null 2>&1; then
    echo "error: elixir/mix not found. install Elixir first or use a release tarball." >&2
    exit 1
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. install Rust first or use a release tarball." >&2
    exit 1
  fi

  echo "==> building native tty helper"
  cargo build --release --manifest-path "$ROOT/rust/ourocode_ipc/Cargo.toml" --bin ourocode_tty
  mkdir -p "$ROOT/bin"
  cp "$ROOT/rust/ourocode_ipc/target/release/ourocode_tty" "$ROOT/bin/ourocode_tty"

  echo "==> building escript"
  (cd "$ROOT" && mix deps.get >/dev/null 2>&1 || true)
  (cd "$ROOT" && mix escript.build)
else
  echo "==> using bundled release binaries"
fi

mkdir -p "$INSTALL_DIR/bin" "$BIN_DIR"
cp "$ROOT/ourocode" "$INSTALL_DIR/ourocode"
cp "$ROOT/bin/ourocode_tty" "$INSTALL_DIR/bin/ourocode_tty"
chmod +x "$INSTALL_DIR/ourocode" "$INSTALL_DIR/bin/ourocode_tty"

cat >"$BIN_DIR/ourocode" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export OUROCODE_TTY="$INSTALL_DIR/bin/ourocode_tty"
exec "$INSTALL_DIR/ourocode" "\$@"
EOF
chmod +x "$BIN_DIR/ourocode"

# The launcher above runs an Erlang escript; make sure the runtime exists before
# we try to invoke it (e.g. the `--detect` call below) or hand control back to
# the user.
ensure_erlang_runtime

# Ourocode surfaces the Ouroboros capability graph. This step is best-effort
# and can be skipped for lean installs or CI with OUROCODE_SKIP_OUROBOROS=1.
OUROBOROS_INSTALL_URL="${OUROBOROS_INSTALL_URL:-https://raw.githubusercontent.com/Q00/ouroboros/main/scripts/install.sh}"
if [ "${OUROCODE_SKIP_OUROBOROS:-0}" = "1" ]; then
  echo "==> skipping Ouroboros install (OUROCODE_SKIP_OUROBOROS=1)"
elif command -v curl >/dev/null 2>&1; then
  echo "==> installing Ouroboros (best effort)"
  if curl -fsSL "$OUROBOROS_INSTALL_URL" | bash; then
    echo "    Ouroboros installed."
  else
    echo "    warning: Ouroboros install did not complete; uvx runtime fallback may still work" >&2
  fi
else
  echo "==> skipping Ouroboros install (curl not found)" >&2
fi

if [ "${OUROCODE_SKIP_OUROBOROS:-0}" != "1" ]; then
  echo "==> ensuring Ouroboros MCP extra (best effort)"
  if command -v uv >/dev/null 2>&1; then
    uv tool install --upgrade --python ">=3.12" ouroboros-ai \
      --with "mcp>=1.26.0,<2.0.0" \
      --with "claude-agent-sdk>=0.1.0" \
      --with "anthropic>=0.52.0" >/dev/null 2>&1 \
      && echo "    MCP extra ensured via uv." \
      || echo "    warning: uv mcp-ensure failed" >&2
  elif command -v pipx >/dev/null 2>&1; then
    pipx install --force "ouroboros-ai[mcp,claude]" >/dev/null 2>&1 \
      && echo "    MCP extra ensured via pipx." \
      || echo "    warning: pipx mcp-ensure failed" >&2
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --user --upgrade "ouroboros-ai[mcp,claude]" >/dev/null 2>&1 \
      && echo "    MCP extra ensured via pip." \
      || echo "    warning: pip mcp-ensure failed" >&2
  fi
fi

# CUA is an optional macOS-only capability. Install the pinned native server,
# overlay, and the small MCP era-compatibility bridge into the same user bin
# directory Ourocode's managed launchd service already exposes to its bridge.
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] \
  && [ "${OUROCODE_SKIP_CUA:-0}" != "1" ]; then
  CUA_VERSION_VALUE="${CUA_VERSION:-v0.9.1}"
  CUA_ASSET_BASE="https://github.com/maestrojeong/cua-rs-mcp/releases/download/${CUA_VERSION_VALUE}"
  CUA_TMP="$(mktemp -d)"
  echo "==> installing CUA ${CUA_VERSION_VALUE} (best effort)"
  if curl -fsSL "${CUA_ASSET_BASE}/cua-rs-macos-arm64" -o "$CUA_TMP/cua-rs" \
    && curl -fsSL "${CUA_ASSET_BASE}/cua-overlay-macos-arm64" -o "$CUA_TMP/cua-overlay" \
    && printf '%s  %s\n' \
      '5d3e2a6eafd18a9a0a6e6137f3dfa471965512591752bb0a456a844ed9db4ebf' "$CUA_TMP/cua-rs" \
      '1b68863c44048ba6dfa626ef09d6f5b91b958764522580b6098b9fbee800f040' "$CUA_TMP/cua-overlay" \
      | shasum -a 256 -c - >/dev/null; then
    install -m 755 "$CUA_TMP/cua-rs" "$BIN_DIR/cua-rs"
    install -m 755 "$CUA_TMP/cua-overlay" "$BIN_DIR/cua-overlay"
    install -m 755 "$ROOT/scripts/ourocode-cua-mcp-bridge" "$BIN_DIR/ourocode-cua-mcp-bridge"
    xattr -d com.apple.quarantine "$BIN_DIR/cua-rs" "$BIN_DIR/cua-overlay" 2>/dev/null || true
    echo "    CUA installed. Grant Accessibility and Screen Recording to Ourocode."
  else
    echo "    warning: CUA download or checksum verification failed; Ourocode still runs without CUA" >&2
  fi
fi

# macOS privacy grants cannot be pre-approved by a shell installer. When a
# final Applications bundle is already present, launch that exact signed app
# into its one-time onboarding surface; temporary build paths must never claim
# TCC identity or trigger protected-folder prompts on its behalf.
if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Ourocode.app" ] \
  && [ "${OUROCODE_SKIP_PERMISSION_ONBOARDING:-0}" != "1" ]; then
  echo "==> opening Ourocode permission onboarding"
  open "/Applications/Ourocode.app" --args --onboarding \
    || echo "    warning: open Ourocode and choose Settings → Computer Use to finish permissions" >&2
fi

echo ""
"$BIN_DIR/ourocode" --detect || true

echo ""
echo "==> ready"
echo "  installed: $INSTALL_DIR"
echo "  command:   $BIN_DIR/ourocode"
echo ""
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "note: add $BIN_DIR to PATH to run 'ourocode' from any shell."
fi
