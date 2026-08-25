#!/usr/bin/env bash
# Build a self-contained ourocode release tarball for the current OS/arch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${OUROCODE_VERSION:-$(grep -E 'version: "' mix.exs | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/')}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
  darwin) OS="darwin" ;;
  linux) OS="linux" ;;
esac

case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64) ARCH="x86_64" ;;
esac

NAME="ourocode-v${VERSION}-${OS}-${ARCH}"
STAGE="$ROOT/dist/$NAME"
TARBALL="$ROOT/dist/$NAME.tar.gz"

echo "==> building ourocode release $NAME"

cargo build --release --manifest-path rust/ourocode_ipc/Cargo.toml --bin ourocode_tty
mkdir -p bin
cp rust/ourocode_ipc/target/release/ourocode_tty bin/ourocode_tty

mix deps.get >/dev/null 2>&1 || true
mix escript.build

rm -rf "$STAGE" "$TARBALL"
mkdir -p "$STAGE/bin" "$STAGE/scripts" "$STAGE/docs/assets"

cp ourocode "$STAGE/ourocode"
cp bin/ourocode_tty "$STAGE/bin/ourocode_tty"
cp install.sh "$STAGE/install.sh"
cp scripts/ourocode-cua-mcp-bridge "$STAGE/scripts/ourocode-cua-mcp-bridge"
cp README.md "$STAGE/README.md"

if [ -f docs/assets/ourocode-readme-hero.png ]; then
  cp docs/assets/ourocode-readme-hero.png "$STAGE/docs/assets/ourocode-readme-hero.png"
fi

chmod +x "$STAGE/ourocode" "$STAGE/bin/ourocode_tty" "$STAGE/install.sh"

(
  cd "$ROOT/dist"
  tar -czf "$TARBALL" "$NAME"
)

# Record the checksum against a bare filename, not "$TARBALL"'s absolute path:
# the .sha256 ships next to the tarball, so `shasum -c` / `sha256sum -c` has to
# resolve it relative to wherever the user downloaded the pair.
(
  cd "$ROOT/dist"
  shasum -a 256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256"
)

echo "==> release ready"
echo "  $TARBALL"
echo "  $TARBALL.sha256"
