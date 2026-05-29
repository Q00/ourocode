#!/usr/bin/env bash
# Install ourocode from either a release tarball directory or a source checkout.
set -euo pipefail

VERSION="${OUROCODE_VERSION:-0.1.12}"
INSTALL_ROOT="${OUROCODE_INSTALL_ROOT:-$HOME/.local/ourocode}"
INSTALL_DIR="${OUROCODE_INSTALL_DIR:-$INSTALL_ROOT/$VERSION}"
BIN_DIR="${OUROCODE_BIN_DIR:-$HOME/.local/bin}"
REPO="${OUROCODE_REPO:-Q00/ourocode}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DOWNLOAD_TMP=""

cleanup() {
  if [ -n "$DOWNLOAD_TMP" ] && [ -d "$DOWNLOAD_TMP" ]; then
    rm -rf "$DOWNLOAD_TMP"
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
  curl -fL "$url" -o "$archive"
  tar -xzf "$archive" -C "$DOWNLOAD_TMP"

  ROOT="$DOWNLOAD_TMP/$name"
  if [ ! -x "$ROOT/ourocode" ] || [ ! -x "$ROOT/bin/ourocode_tty" ]; then
    echo "error: release archive did not contain expected ourocode binaries." >&2
    exit 1
  fi
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

echo "==> ourocode install"

need_build=0
if [ ! -x "$ROOT/ourocode" ] || [ ! -x "$ROOT/bin/ourocode_tty" ]; then
  need_build=1
fi

if [ "${OUROCODE_BUILD_FROM_SOURCE:-0}" = "1" ]; then
  need_build=1
fi

if [ "$need_build" = "1" ]; then
  if [ "${OUROCODE_BUILD_FROM_SOURCE:-0}" != "1" ] && [ ! -f "$ROOT/mix.exs" ]; then
    download_release
    need_build=0
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
