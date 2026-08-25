# RFC 0006: Shared MCP host migration planner

Status: planner, guarded filesystem executor, and explicit Settings preview /
confirmation UI implemented; no migration is automatic.

## Decision

Ourocode must not save renderer memory while allowing every Claude Code or
Codex tab to launch another complete Ouroboros Python stdio runtime. Supported
host registrations will eventually point to the one launchd-supervised
`http://127.0.0.1:8976/mcp` service already owned by
`SharedOuroborosServiceSupervisor`.

The policy boundary is deliberately non-mutating. The planner accepts
only a secret-free projection of the named MCP entry: host/scope, server name,
stdio executable/arguments, and an opaque host-owned rollback snapshot
reference. Its type cannot contain environment values, headers, bearer tokens,
or unrelated configuration. It emits argv arrays rather than a shell string.

For a verified Codex stdio registration named `ouroboros`, the preview is:

```text
codex mcp remove ouroboros
codex mcp add ouroboros --url http://127.0.0.1:8976/mcp
```

Claude `user` and `local` registrations are planned independently with exact
`--scope` arguments. `project` scope is outside this first migration contract.
An existing HTTP registration is not rewritten.

The separately reviewed filesystem executor implements only these concrete
host locations and shapes:

- Codex user config at an explicitly supplied home directory's
  `.codex/config.toml`, with one simple `[mcp_servers.ouroboros]` table containing
  single-line `command` and `args` values. One immediately adjacent
  `[mcp_servers.ouroboros.env]` subtable is supported when every key is unique
  and bounded to a literal JSON-compatible string value. The subtable is part
  of the replaced stdio registration, is never projected into preview text,
  and remains byte-exact in the private rollback snapshot.
- Claude user config at an explicitly supplied home directory's `.claude.json`,
  at `mcpServers.ouroboros`.
- Claude local config in that same `.claude.json`, at the exact, caller-supplied
  canonical project key under `projects[project].mcpServers.ouroboros`.

Additional/nested Codex subtables, a separated environment subtable, comments
or unknown fields inside the Ouroboros table, Claude unknown fields inside the
Ouroboros entry, Claude project-scope files, and plugin-owned registrations
fail closed. Unrelated root settings, projects, profiles, and sibling MCP
entries are preserved. Claude JSON is semantically reserialized, and the
byte-exact original remains available for rollback.

## Safety and rollback

- Only literal HTTP loopback `/mcp` URLs with an explicit port are eligible.
- The endpoint must match the pinned shared-service label, schema, Ouroboros
  version, owner-only artifacts, and a successful readiness probe.
- Missing rollback snapshot ID or configuration generation fails closed.
- Dry-run planning and apply authorization are separate values. The executor
  retains original and replacement bytes privately; the UI receives only a
  secret-free entry diff. Apply requires the exact preview UUID and confirmation
  phrase. Rollback requires its opaque token and a separate exact phrase.
- Preview performs no filesystem mutation. Apply reopens the target and requires
  the same device, inode, size, mtime, permissions, and bytes. It creates a
  mode-`0600` backup in an owner-only directory, fsyncs it, then uses macOS
  `RENAME_SWAP` to atomically capture and verify the displaced inode before
  committing. A racing edit is swapped back rather than overwritten.
- Targets must be regular, owner-owned, owner-only files with one hard link.
  Symlinks, group/world permission bits, oversized files, and unsafe backup
  directories fail closed. The original permission bits are preserved.
- Rollback checks that both the currently installed bytes/inode and the backup
  still match its private authority before atomically restoring. It never
  clobbers edits made after migration.
- No API in the planner writes `~/.codex`, `~/.claude`, `.mcp.json`, launchd,
  or running processes. The executor receives explicit file URLs and does not
  inspect or signal live MCP processes.

## Exact Claude plugin blocker

Claude plugin MCP servers are lifecycle-owned and namespaced. The installed CLI
can remove user/local/project MCP registrations, but Ourocode has no verified
command or host contract that disables or overrides one namespaced server while
preserving the rest of its plugin. Replacing a similarly named user entry would
leave the plugin stdio child active and falsely claim deduplication. The planner
therefore returns `claudePluginCannotBeDisabledOrOverridden` and produces no
commands. Plugin migration remains blocked until Claude exposes an authoritative
per-server disable/override capability (or the Ouroboros plugin itself adopts
the shared endpoint).

## Verification

`test-shared-mcp-host-migration.sh` compiles with warnings as errors and covers
Codex uvx detection, Claude user/local separation, plugin refusal, unrelated
stdio and existing HTTP rejection, remote/unverified endpoint rejection,
rollback preservation, and exact explicit apply confirmation.

`test-shared-mcp-host-migration-executor.sh` ordinarily uses only temporary
fixture homes. It covers exact Codex/Claude locations and schemas (including
the adjacent Codex `env` subtable), a secret-free diff, no write before exact
confirmation, stale-preview refusal before backup creation,
owner/mode/symlink/hard-link checks, sibling preservation, byte-exact rollback,
and refusal to overwrite a post-migration edit. An opt-in
`OUROCODE_TEST_LIVE_CODEX_PREVIEW=/absolute/config.toml` acting check calls only
`preview` against that explicit file and proves its complete bytes are
unchanged; it never calls apply or creates rollback storage. Missing Claude
registrations remain `registrationMissing`, not a fabricated migration.
