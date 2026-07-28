# Ourocode

![Ourocode TUI demo](docs/assets/ourocode-tui-demo.gif)

Ourocode is a terminal workbench for planning real work, delegating it to guided agents, and verifying the result without leaving your shell. It gives you a fast keyboard UI, structured interviews with selectable answers, active-work views, connected-tool checks, and JSON evidence for automation.

Product site draft: [docs/site](docs/site/index.html)

The current release is optimized for local macOS development and guided workflow testing.

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

Install the latest prerelease build on macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/Q00/ourocode/release/bootstrap/install.sh | bash
```

Install a Windows release from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>
```

Then run:

```text
ourocode
ourocode --version
```

With no arguments, `ourocode` uses the current working directory as the project
directory. Pass `--project-dir PATH` (or set `OUROCODE_PROJECT_DIR`) to point it
elsewhere.

### Requirements For Running Ourocode

The bundled `ourocode` is an Erlang escript, so it needs the **Erlang/OTP
runtime** (`escript`/`erl`) on your `PATH`.

Windows users need:

- Windows 10/11, Windows Server 2019, or Windows Server 2022.
- Windows PowerShell 5.1 or PowerShell 7+.
- Erlang/OTP with `erl.exe` and `escript.exe` available on `PATH`.

Check the Windows runtime prerequisites:

```powershell
$PSVersionTable.PSVersion
Get-Command escript.exe
erl -eval "erlang:display(erlang:system_info(otp_release)), halt()." -noshell
```

macOS and Linux users need Erlang/OTP with `escript` and `erl` on `PATH`. The
Unix installer installs it best-effort (Homebrew on macOS, `apt`/`dnf` on
Linux); if that is not possible it stops with manual instructions. Install it
yourself with `brew install erlang`, `sudo apt-get install erlang`, or `sudo dnf
install erlang`. Set `OUROCODE_SKIP_ERLANG=1` to bypass the check on Unix.

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

Install from GitHub without cloning on macOS or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/Q00/ourocode/release/bootstrap/install.sh | bash
ourocode
```

`install.sh` downloads the matching GitHub Release tarball, installs `ourocode` into `~/.local/ourocode/<version>`, and writes a launcher at `~/.local/bin/ourocode`. The launcher sets `OUROCODE_TTY` so the installed escript can find the bundled native tty helper. It also ensures the Erlang/OTP runtime is available (see [Requirements](#requirements)), since the escript cannot run without it.

When run from a source checkout, the same installer uses bundled release binaries if present, or builds from source when needed. Set `OUROCODE_BUILD_FROM_SOURCE=1` to force a local build.

Set `OUROCODE_SKIP_OUROBOROS=1` to skip the best-effort Ouroboros install step.

### Windows PowerShell Install

The Windows path uses PowerShell only. It does not require Bash, Git Bash, WSL,
`tar`, `chmod`, or a permanent execution-policy change.

Final-user prerequisites:

- Windows 10/11, Windows Server 2019, or Windows Server 2022.
- Windows PowerShell 5.1 or PowerShell 7+.
- Erlang/OTP on `PATH`, including `erl.exe` and `escript.exe`.

Verify prerequisites before installing:

```powershell
$PSVersionTable.PSVersion
Get-Command escript.exe
erl -eval "erlang:display(erlang:system_info(otp_release)), halt()." -noshell
```

Install a release:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>
ourocode --version
```

`-ExecutionPolicy Bypass` applies only to that process. The installer does not
change the machine or user execution policy permanently.

When downloading a release, the installer downloads the matching `.sha256`
sidecar and verifies the zip before installing. For a local zip, pass `-Sha256`
with the expected hash or keep the `.zip.sha256` sidecar next to the zip. It writes the selected version under
`%LOCALAPPDATA%\Ourocode\<version>`, creates the launcher in
`%LOCALAPPDATA%\Ourocode\bin`, and updates the user `PATH` so new PowerShell or
`cmd.exe` windows can run `ourocode`. If the current shell was open before
install, restart the shell or refresh `PATH` before running the launcher.

Uninstall all Windows versions and remove the launcher/PATH entry:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -AllVersions
```

Then rerun the installer. This install/uninstall loop is safe to repeat:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -AllVersions
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version <version>
```

If a Windows build does not include `ourocode_tty.exe`, Ourocode still starts
through the escript launcher and reports the reduced TUI helper capability
instead of requiring Bash or WSL.

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

Generated artifacts:

```text
dist/ourocode-v0.1.13-darwin-arm64.tar.gz
dist/ourocode-v0.1.13-darwin-arm64.tar.gz.sha256
```

Install from an unpacked release:

```bash
tar -xzf dist/ourocode-v0.1.13-darwin-arm64.tar.gz
cd ourocode-v0.1.13-darwin-arm64
./install.sh
ourocode
```

Homebrew is planned but not yet the supported install path:

```bash
brew tap Q00/ourocode
brew install ourocode
```

Longer term, Ourocode should move toward a single self-contained binary or app bundle so users do not need to install Elixir/Rust just to run it.

### Windows Release Builder Prerequisites

Developers and release builders need the final-user prerequisites plus:

- Git.
- Erlang/OTP.
- Elixir and Mix.
- Rust stable with the MSVC target for the release architecture.
- Microsoft C++ Build Tools / MSVC Build Tools.

Build a Windows release zip:

```powershell
.\scripts\package-windows.ps1 -Version <version>
```

The Windows package command emits `dist\ourocode-v<version>-windows-x64.zip`
and a `.sha256` file for checksum verification by the PowerShell installer.

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
