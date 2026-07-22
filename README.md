# Ourocode

![Ourocode TUI demo](docs/assets/ourocode-tui-demo.gif)

Ourocode is a terminal workbench for planning real work, delegating it to guided agents, and verifying the result without leaving your shell. It gives you a fast keyboard UI, structured interviews with selectable answers, active-work views, connected-tool checks, and JSON evidence for automation.

Product site draft: [docs/site](docs/site/index.html)

The current release supports local macOS and Linux (x86_64/arm64) development and guided workflow testing.

## What It Does

- Starts structured work with `ooo pm <goal>` and keeps the first useful choice visible quickly.
- Shows delegated work with task, state, current output, and actions.
- Turns interview checkpoints into focused pickers with number keys, custom answers, pause, and cancel.
- Exposes `/agents`, `/sessions`, `/mcps`, `/config`, `/sandbox`, and `/verify` as product surfaces, not only debug logs.
- Runs headless with `--prompt` and `--format json` for scripts, CI, and remote operators.
- Supports command discovery with `/`, `ooo`, `@file`, and prompt overlays.
- Writes current visual verification captures to `docs/assets/visual/` when
  `/verify` or `--verify` runs, including first start, PM picker, agents,
  cancel, verify, theme, and README media.

## Quick Start

Install the latest prerelease build:

```bash
curl -fsSL https://raw.githubusercontent.com/Ouro-labs/ourocode/release/bootstrap/install.sh | bash
```

Then run:

```bash
ourocode
```

With no arguments, `ourocode` uses the current working directory as the project
directory. Pass `--project-dir PATH` (or set `OUROCODE_PROJECT_DIR`) to point it
elsewhere.

### Requirements

The bundled `ourocode` is an Erlang escript, so it needs the **Erlang/OTP
runtime** (`escript`/`erl`) on your `PATH`. The installer installs it
best-effort (Homebrew on macOS, `apt`/`dnf` on Linux); if that is not possible
it stops with manual instructions. Install it yourself with `brew install
erlang`, `sudo apt-get install erlang`, or `sudo dnf install erlang`. Set
`OUROCODE_SKIP_ERLANG=1` to bypass the check.

Prebuilt release tarballs are published for **Linux** (`x86_64`, `arm64`) and
**macOS** (`arm64`). On other platforms, install from a source checkout or set
`OUROCODE_BUILD_FROM_SOURCE=1` to build locally (needs Elixir + Rust).

Optional model backends:

- Claude CLI
- Codex CLI
- Gemini CLI
- ChatGPT/Codex login

For a local source checkout:

```bash
./install.sh
ourocode
```

Detect available model backends:

```bash
./ourocode --detect
```

Run product verification or drive Ourocode from automation:

```bash
./ourocode --verify --format json --project-dir .
./ourocode --prompt "/agents" --format json --project-dir .
./ourocode --prompt "ooo pm design plugin onboarding" --format json --project-dir .
```

See [Headless CLI Automation](docs/remote-headless-control.md) for JSON
evidence, active-work views, connected-tool readiness, and safety posture.

Inside the TUI:

```text
/               choose ooo pm, ooo interview, or ooo auto
/help           show the guided starts and command reference
/commands       list every available command
/model          choose a model backend
/login          sign in for ChatGPT/Codex OAuth
/agents         inspect active work and answers waiting on you
/mcp            show connected tools and readiness
/mcps           show connected tools and readiness
/config         show local setup status
/theme          switch light or dark mode
/verify         run product checks
/sandbox        inspect safety mode, roots, network posture, and actions
ooo pm          shape product requirements with answer choices
ooo interview   start a structured interview flow
ooo auto        interview, draft a plan, then execute after approval
@               mention project files
Ctrl-G          show active key help
```

## Install Locally

Install from GitHub without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/Ouro-labs/ourocode/release/bootstrap/install.sh | bash
ourocode
```

`install.sh` downloads the matching GitHub Release tarball, installs `ourocode` into `~/.local/ourocode/<version>`, and writes a launcher at `~/.local/bin/ourocode`. The launcher sets `OUROCODE_TTY` so the installed escript can find the bundled native tty helper. It also ensures the Erlang/OTP runtime is available (see [Requirements](#requirements)), since the escript cannot run without it.

When run from a source checkout, the same installer uses bundled release binaries if present, or builds from source when needed. Set `OUROCODE_BUILD_FROM_SOURCE=1` to force a local build.

Set `OUROCODE_SKIP_OUROBOROS=1` to skip the best-effort Ouroboros install step.

## Package A Release

Build a local release tarball:

```bash
./scripts/package.sh
```

The release contains:

```text
ourocode
bin/ourocode_tty
install.sh
README.md
```

Generated artifacts (named for the host platform, for example):

```text
dist/ourocode-v0.1.15-beta-1-linux-x86_64.tar.gz
dist/ourocode-v0.1.15-beta-1-linux-x86_64.tar.gz.sha256
```

`scripts/package.sh` builds a tarball for the machine it runs on. The `release`
workflow (`.github/workflows/release.yml`) runs it on `ubuntu-latest`,
`ubuntu-24.04-arm`, and `macos-14` and attaches `linux-x86_64`, `linux-arm64`,
and `darwin-arm64` tarballs (plus `.sha256`) to each published GitHub Release.
A `windows-latest` job runs `scripts/package-windows.ps1` and attaches
`ourocode-v<version>-windows-x64.zip` (plus `.sha256`) to the same release.

Pre-releases such as `v0.1.15-beta-1` are published as GitHub *pre-releases*,
so `install.sh` keeps resolving the latest **stable** tag by default. Opt into a
beta explicitly:

```bash
OUROCODE_VERSION=0.1.15-beta-1 ./install.sh
```

```powershell
.\install.ps1 -Version 0.1.15-beta-1
```

Install from an unpacked release:

```bash
tar -xzf dist/ourocode-v0.1.15-beta-1-linux-x86_64.tar.gz
cd ourocode-v0.1.15-beta-1-linux-x86_64
./install.sh
ourocode
```

Homebrew is planned but not yet the supported install path:

```bash
brew tap Ouro-labs/ourocode
brew install ourocode
```

Longer term, Ourocode should move toward a single self-contained binary or app bundle so users do not need to install Elixir/Rust just to run it.

## Architecture

This section is for contributors and plugin authors. Day-to-day users should
start with `ourocode`, `ooo pm <goal>`, `/agents`, and `--verify`.

```text
Terminal TUI
  -> command registry and prompt overlays
  -> runtime dispatcher
  -> MCP transport layer
  -> Ouroboros / model backends
  -> journaled event stream
  -> dashboard projections
```

Key areas:

- `lib/ourocode/terminal/` - raw terminal UI, key decoding, palette, prompt history, screen diffing
- `lib/ourocode/runtime/` - workflow orchestration, dispatch, focus state, stream supervision
- `lib/ourocode/mcp/` - stdio, SSE, and streamable HTTP normalization
- `lib/ourocode/wonder_tool/` - decision request parsing and answer capture
- `lib/ourocode/dashboard/` - data-only pane projections
- `rust/ourocode_ipc/` - native tty helper

## Development

Run tests:

```bash
mix test
```

Run focused terminal tests:

```bash
mix test test/ourocode/terminal
```

Build everything:

```bash
./build.sh
```

## Status

This is an early release branch for getting real users onto the terminal workflow. The current priority is packaging, installer polish, and feedback from actual guided interview sessions.
