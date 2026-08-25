#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
UI="$APP_ROOT/Sources/OurocodeDesktop/SharedMCPMigrationSettings.swift"
SETTINGS="$APP_ROOT/Sources/OurocodeDesktop/TerminalPreferences.swift"
MAIN="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

# The settings surface observes the existing shared runtime and independently
# verifies exact owner-only artifacts plus MCP readiness before enabling review.
rg -Fq 'runtime.whenSettled' "$UI"
rg -Fq 'SharedOuroborosServiceSupervisor().attachToExistingService(paths: paths)' "$UI"
rg -Fq 'ownershipArtifactsVerified: true' "$UI"
rg -Fq 'readinessProbeSucceeded: true' "$UI"
rg -Fq 'endpoint == SharedOuroborosResolver.defaultEndpoint' "$UI"

# Only the exact user-level Codex and Claude registrations are in scope.
rg -Fq 'case .codexUser: return .codex' "$UI"
rg -Fq 'case .claudeUser: return .claude(scope: .user)' "$UI"
rg -Fq 'SharedMCPHostConfigLocator.supportedTarget(' "$UI"
rg -Fq 'The user configuration file was not found or is not a regular file.' "$UI"
rg -Fq 'The configuration is not owner-only (0600), so Ourocode will not read it.' "$UI"

# Preview remains secret-free and mutations stay behind the reviewed executor
# plus its exact phrase contracts. No subprocess or shell-string adapter exists.
rg -Fq 'self.executor.preview(target: configTarget, endpoint: endpointAttestation)' "$UI"
rg -Fq 'SharedMCPMigrationHostCard' "$UI"
rg -Fq 'diff.before' "$UI"
rg -Fq 'diff.after' "$UI"
rg -Fq 'diff.preservedSiblingServerCount' "$UI"
rg -Fq 'SharedMCPHostMigrationPlanner.applyConfirmationPhrase' "$UI"
rg -Fq 'SharedMCPHostMigrationExecutor.rollbackConfirmationPhrase' "$UI"
rg -Fq 'confirm.isEnabled = false' "$UI"
rg -Fq 'confirm.isEnabled = value == phrase' "$UI"
rg -Fq 'self.executor.apply(' "$UI"
rg -Fq 'self.executor.rollback(' "$UI"
if rg -n 'Process\(|/bin/(sh|zsh|bash)|shell string' "$UI"; then
  echo "FAIL: migration Settings introduced a subprocess or shell-string path" >&2
  exit 1
fi

# Merely opening Settings can verify the service, but cannot preview or mutate
# a host file. Preview, Apply, and Restore each remain explicit controls.
rg -Fq 'func activate()' "$UI"
rg -Fq 'beginEndpointVerification()' "$UI"
rg -Fq 'let previewButton = NSButton(title: "Preview change"' "$UI"
rg -Fq 'let applyButton = NSButton(title: "Apply…"' "$UI"
rg -Fq 'let rollbackButton = NSButton(title: "Restore…"' "$UI"
rg -Fq 'migrationController.activate()' "$SETTINGS"
rg -Fq 'sharedOuroborosService: sharedOuroborosService' "$MAIN"

# Essential state changes and destructive controls are named for VoiceOver.
rg -Fq 'setAccessibilityLabel("Shared MCP service status")' "$UI"
rg -Fq 'setAccessibilityLabel("Apply " + host.title + " shared MCP change")' "$UI"
rg -Fq 'setAccessibilityLabel("Restore " + host.title + " MCP registration")' "$UI"
rg -Fq 'NSAccessibility.post(element: endpointStatus, notification: .valueChanged)' "$UI"

echo "PASS: shared MCP Settings is read-only by default, secret-free, phrase-gated, and accessible"
