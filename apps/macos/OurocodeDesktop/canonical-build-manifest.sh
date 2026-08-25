#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
CANONICAL_BUNDLE_IDENTIFIER="com.ourolabs.ourocode"
MANIFEST_RELATIVE_PATH="Contents/Resources/OurocodeBuildManifest.json"

usage() {
  cat >&2 <<'EOF'
Usage:
  canonical-build-manifest.sh source-digest
  canonical-build-manifest.sh write --app APP --profile release|development \
    --engine NAME [--provider-scope SCOPE] --expected-source-digest SHA256
  canonical-build-manifest.sh verify --app APP --expected-profile release|development \
    [--require-current-source]
EOF
  exit 64
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# A bundle signature seals its resources, including this manifest. Signing the
# outer app therefore changes the LC_CODE_SIGNATURE bytes in the main Mach-O
# after the manifest has been written. Hash the executable's loadable content
# instead of those circular signature bytes: a temporary copy has only its
# code signature removed, while every code/data byte remains covered.
executable_content_digest() {
  local executable="$1"
  local unsigned_copy
  unsigned_copy=$(mktemp "${TMPDIR:-/tmp}/ourocode-executable-content.XXXXXX")
  cp "$executable" "$unsigned_copy"
  codesign --remove-signature "$unsigned_copy" >/dev/null 2>&1 || true
  sha256_file "$unsigned_copy"
  rm -f "$unsigned_copy"
}

source_input_list() {
  local list_file="$1"
  local input_path
  : >"$list_file"

  for input_path in \
    "$APP_ROOT/Sources" \
    "$APP_ROOT/Resources" \
    "$REPOSITORY_ROOT/crates/ouro-broker/src" \
    "$REPOSITORY_ROOT/crates/ouro-render-ffi/src" \
    "$REPOSITORY_ROOT/crates/ouro-session/src" \
    "$REPOSITORY_ROOT/crates/ouro-terminal-ghostty/src"
  do
    [[ -d "$input_path" ]] || continue
    find "$input_path" -type f -print >>"$list_file"
  done

  for input_path in \
    "$APP_ROOT/Package.swift" \
    "$APP_ROOT/Package.resolved" \
    "$APP_ROOT/AppIconGenerator.swift" \
    "$APP_ROOT/THIRD_PARTY_NOTICES.md" \
    "$APP_ROOT/build-app.sh" \
    "$APP_ROOT/build-dev-ghostty-app.sh" \
    "$APP_ROOT/canonical-build-manifest.sh" \
    "$REPOSITORY_ROOT/Cargo.toml" \
    "$REPOSITORY_ROOT/Cargo.lock" \
    "$REPOSITORY_ROOT/rust-toolchain.toml" \
    "$REPOSITORY_ROOT/crates/ouro-broker/Cargo.toml" \
    "$REPOSITORY_ROOT/crates/ouro-render-ffi/Cargo.toml" \
    "$REPOSITORY_ROOT/crates/ouro-session/Cargo.toml" \
    "$REPOSITORY_ROOT/crates/ouro-terminal-ghostty/Cargo.toml" \
    "$REPOSITORY_ROOT/scripts/assert-static-archive-macos-minimum.zsh" \
    "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"
  do
    [[ -f "$input_path" ]] && print -r -- "$input_path" >>"$list_file"
  done

  LC_ALL=C sort -u -o "$list_file" "$list_file"
}

tree_digest() {
  local root="$1"
  local list_file="$2"
  local input_path relative digest
  while IFS= read -r input_path; do
    relative="${input_path#$root/}"
    digest=$(sha256_file "$input_path")
    printf '%s\t%s\n' "$relative" "$digest"
  done <"$list_file" | shasum -a 256 | awk '{print $1}'
}

current_source_digest() {
  local list_file
  list_file=$(mktemp "${TMPDIR:-/tmp}/ourocode-source-inputs.XXXXXX")
  source_input_list "$list_file"
  tree_digest "$REPOSITORY_ROOT" "$list_file"
  rm -f "$list_file"
}

helper_digest() {
  local helpers_root="$1"
  local list_file
  list_file=$(mktemp "${TMPDIR:-/tmp}/ourocode-helper-inputs.XXXXXX")
  find "$helpers_root" -type f -print | LC_ALL=C sort >"$list_file"
  tree_digest "$helpers_root" "$list_file"
  rm -f "$list_file"
}

json_value() {
  local manifest="$1"
  local key="$2"
  plutil -extract "$key" raw -o - "$manifest"
}

validate_bundle_identifier() {
  local profile="$1"
  local bundle_identifier="$2"
  if [[ ! "$bundle_identifier" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]]; then
    echo "Invalid bundle identifier: $bundle_identifier" >&2
    exit 65
  fi
  if [[ "$profile" == "release" && "$bundle_identifier" != "$CANONICAL_BUNDLE_IDENTIFIER" ]]; then
    echo "Release builds must use $CANONICAL_BUNDLE_IDENTIFIER" >&2
    exit 65
  fi
  if [[ "$profile" == "development" && "$bundle_identifier" == "$CANONICAL_BUNDLE_IDENTIFIER" ]]; then
    echo "Development and QA builds may not use $CANONICAL_BUNDLE_IDENTIFIER" >&2
    exit 65
  fi
}

write_manifest() {
  local app_bundle="$1"
  local profile="$2"
  local engine="$3"
  local expected_source_digest="$4"
  local executable="$app_bundle/Contents/MacOS/Ourocode"
  local helpers_root="$app_bundle/Contents/Helpers"
  local info_plist="$app_bundle/Contents/Info.plist"
  local manifest="$app_bundle/$MANIFEST_RELATIVE_PATH"
  local source_digest bundle_identifier executable_digest helpers_digest
  local git_commit git_tree source_file_count list_file temp_plist provider_scope build_id

  [[ "$app_bundle" == /*.app ]] || usage
  [[ "$profile" == "release" || "$profile" == "development" ]] || usage
  if [[ "$profile" == "release" && "$engine" != "ghostty-metal" ]]; then
    echo "Release manifests require the audited ghostty-metal engine" >&2
    exit 65
  fi
  [[ -x "$executable" && -d "$helpers_root" && -f "$info_plist" ]] || {
    echo "Incomplete Ourocode app bundle: $app_bundle" >&2
    exit 66
  }

  source_digest=$(current_source_digest)
  if [[ "$source_digest" != "$expected_source_digest" ]]; then
    echo "Ourocode source changed while the app was building; rebuild from the current tree" >&2
    echo "build started at: $expected_source_digest" >&2
    echo "current source:  $source_digest" >&2
    exit 75
  fi

  bundle_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")
  validate_bundle_identifier "$profile" "$bundle_identifier"
  provider_scope="$5"
  if [[ ! "$provider_scope" =~ '^[A-Za-z0-9._-]+$' ]]; then
    echo "Invalid provider scope: $provider_scope" >&2
    exit 65
  fi
  if [[ "$profile" == "release" && "$provider_scope" != "shared-real" ]]; then
    echo "Release manifests require provider scope shared-real" >&2
    exit 65
  fi
  executable_digest=$(executable_content_digest "$executable")
  helpers_digest=$(helper_digest "$helpers_root")
  build_id=$(printf '%s\n' "$profile" "$bundle_identifier" "$engine" "$provider_scope" \
    "$source_digest" "$executable_digest" "$helpers_digest" \
    | shasum -a 256 | awk '{print substr($1, 1, 24)}')
  git_commit=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || print unknown)
  git_tree=$(git -C "$REPOSITORY_ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || print unknown)
  list_file=$(mktemp "${TMPDIR:-/tmp}/ourocode-source-count.XXXXXX")
  source_input_list "$list_file"
  source_file_count=$(wc -l <"$list_file" | tr -d ' ')
  rm -f "$list_file"

  mkdir -p "${manifest:h}"
  temp_plist=$(mktemp "${TMPDIR:-/tmp}/ourocode-build-manifest.XXXXXX")
  plutil -create xml1 "$temp_plist"
  plutil -insert schema_version -integer 2 "$temp_plist"
  plutil -insert product -string Ourocode "$temp_plist"
  plutil -insert build_id -string "$build_id" "$temp_plist"
  plutil -insert build_profile -string "$profile" "$temp_plist"
  plutil -insert bundle_identifier -string "$bundle_identifier" "$temp_plist"
  plutil -insert terminal_engine -string "$engine" "$temp_plist"
  plutil -insert provider_scope -string "$provider_scope" "$temp_plist"
  plutil -insert source_git_commit -string "$git_commit" "$temp_plist"
  plutil -insert source_git_tree -string "$git_tree" "$temp_plist"
  plutil -insert source_inputs_sha256 -string "$source_digest" "$temp_plist"
  plutil -insert source_file_count -integer "$source_file_count" "$temp_plist"
  plutil -insert executable_content_sha256 -string "$executable_digest" "$temp_plist"
  plutil -insert helpers_sha256 -string "$helpers_digest" "$temp_plist"
  plutil -insert built_at_utc -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$temp_plist"
  plutil -convert json -o "$manifest" "$temp_plist"
  rm -f "$temp_plist"

  plutil -insert OurocodeBuildProfile -string "$profile" "$info_plist"
  plutil -insert OurocodeBuildChannel -string "$profile" "$info_plist"
  plutil -insert OurocodeBuildID -string "$build_id" "$info_plist"
  plutil -insert OurocodeSourceInputsSHA256 -string "$source_digest" "$info_plist"
  plutil -insert OurocodeSourceGitCommit -string "$git_commit" "$info_plist"
  plutil -insert OurocodeProviderScope -string "$provider_scope" "$info_plist"
}

verify_manifest() {
  local app_bundle="$1"
  local expected_profile="$2"
  local require_current_source="$3"
  local executable="$app_bundle/Contents/MacOS/Ourocode"
  local helpers_root="$app_bundle/Contents/Helpers"
  local info_plist="$app_bundle/Contents/Info.plist"
  local manifest="$app_bundle/$MANIFEST_RELATIVE_PATH"
  local profile bundle_identifier recorded actual

  [[ "$app_bundle" == /*.app ]] || usage
  [[ "$expected_profile" == "release" || "$expected_profile" == "development" ]] || usage
  [[ -x "$executable" && -d "$helpers_root" && -f "$info_plist" && -f "$manifest" ]] || {
    echo "Ourocode bundle or canonical build manifest is missing: $app_bundle" >&2
    exit 66
  }

  [[ "$(json_value "$manifest" schema_version)" == "2" ]] || {
    echo "Unsupported Ourocode build manifest schema" >&2
    exit 65
  }
  [[ "$(json_value "$manifest" product)" == "Ourocode" ]] || {
    echo "Build manifest does not describe Ourocode" >&2
    exit 65
  }
  profile=$(json_value "$manifest" build_profile)
  [[ "$profile" == "$expected_profile" ]] || {
    echo "Expected a $expected_profile app, found manifest profile $profile" >&2
    exit 65
  }
  bundle_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")
  validate_bundle_identifier "$profile" "$bundle_identifier"
  if [[ "$profile" == "release" \
      && "$(json_value "$manifest" terminal_engine)" != "ghostty-metal" ]]; then
    echo "Release manifest does not use the audited ghostty-metal engine" >&2
    exit 65
  fi
  [[ "$(json_value "$manifest" bundle_identifier)" == "$bundle_identifier" ]] || {
    echo "Bundle identifier does not match the build manifest" >&2
    exit 65
  }
  recorded=$(json_value "$manifest" provider_scope)
  [[ "$(plutil -extract OurocodeProviderScope raw -o - "$info_plist")" == "$recorded" ]] || {
    echo "Info.plist provider scope does not match the build manifest" >&2
    exit 65
  }
  if [[ "$profile" == "release" && "$recorded" != "shared-real" ]]; then
    echo "Release manifest does not use provider scope shared-real" >&2
    exit 65
  fi

  recorded=$(json_value "$manifest" executable_content_sha256)
  actual=$(executable_content_digest "$executable")
  [[ "$recorded" == "$actual" ]] || {
    echo "Ourocode executable does not match its build manifest" >&2
    exit 65
  }
  recorded=$(json_value "$manifest" helpers_sha256)
  actual=$(helper_digest "$helpers_root")
  [[ "$recorded" == "$actual" ]] || {
    echo "Ourocode helpers do not match their build manifest" >&2
    exit 65
  }
  [[ "$(plutil -extract OurocodeBuildProfile raw -o - "$info_plist")" == "$profile" ]] || {
    echo "Info.plist build profile does not match the build manifest" >&2
    exit 65
  }
  [[ "$(plutil -extract OurocodeBuildChannel raw -o - "$info_plist")" == "$profile" ]] || {
    echo "Info.plist build channel does not match the build manifest" >&2
    exit 65
  }
  [[ "$(plutil -extract OurocodeBuildID raw -o - "$info_plist")" \
      == "$(json_value "$manifest" build_id)" ]] || {
    echo "Info.plist build ID does not match the build manifest" >&2
    exit 65
  }
  recorded=$(json_value "$manifest" source_inputs_sha256)
  [[ "$(plutil -extract OurocodeSourceInputsSHA256 raw -o - "$info_plist")" == "$recorded" ]] || {
    echo "Info.plist source digest does not match the build manifest" >&2
    exit 65
  }
  if [[ "$require_current_source" == "1" ]]; then
    actual=$(current_source_digest)
    [[ "$recorded" == "$actual" ]] || {
      echo "Ourocode app is stale for the current source tree; rebuild it before launch or packaging" >&2
      echo "app source:     $recorded" >&2
      echo "current source: $actual" >&2
      exit 75
    }
  fi
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || usage
shift

case "$COMMAND" in
  source-digest)
    [[ $# -eq 0 ]] || usage
    current_source_digest
    ;;
  write|verify)
    APP_BUNDLE=""
    PROFILE=""
    ENGINE=""
    PROVIDER_SCOPE="shared-real"
    EXPECTED_SOURCE_DIGEST=""
    REQUIRE_CURRENT_SOURCE=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app) APP_BUNDLE="${2:-}"; shift 2 ;;
        --profile|--expected-profile) PROFILE="${2:-}"; shift 2 ;;
        --engine) ENGINE="${2:-}"; shift 2 ;;
        --provider-scope) PROVIDER_SCOPE="${2:-}"; shift 2 ;;
        --expected-source-digest) EXPECTED_SOURCE_DIGEST="${2:-}"; shift 2 ;;
        --require-current-source) REQUIRE_CURRENT_SOURCE=1; shift ;;
        *) usage ;;
      esac
    done
    [[ -n "$APP_BUNDLE" && -n "$PROFILE" ]] || usage
    APP_BUNDLE="${APP_BUNDLE:A}"
    if [[ "$COMMAND" == "write" ]]; then
      [[ -n "$ENGINE" && "$EXPECTED_SOURCE_DIGEST" =~ '^[0-9a-f]{64}$' ]] || usage
      write_manifest "$APP_BUNDLE" "$PROFILE" "$ENGINE" "$EXPECTED_SOURCE_DIGEST" \
        "$PROVIDER_SCOPE"
    else
      [[ -z "$ENGINE" && -z "$EXPECTED_SOURCE_DIGEST" ]] || usage
      verify_manifest "$APP_BUNDLE" "$PROFILE" "$REQUIRE_CURRENT_SOURCE"
    fi
    ;;
  *) usage ;;
esac
