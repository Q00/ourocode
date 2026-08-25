#!/bin/zsh
set -euo pipefail

# LaunchServices keys on CFBundleIdentifier, not on the filename.  A stale QA
# bundle carrying the release identifier can therefore make `open -a
# Ourocode` start an older build.  This audit is intentionally read-only: it
# reports every candidate and never removes or unregisters an application.

APP_ROOT="${0:A:h}"
CANONICAL_ID="${OUROCODE_RELEASE_BUNDLE_IDENTIFIER:-com.ourolabs.ourocode}"
CANONICAL_BUILD_BUNDLE="${OUROCODE_CANONICAL_BUILD_BUNDLE:-$APP_ROOT/.build/Ourocode.app}"
APPLICATION_BUNDLE="${OUROCODE_APPLICATION_BUNDLE:-/Applications/Ourocode.app}"

if [[ "$CANONICAL_BUILD_BUNDLE" != /* || "$APPLICATION_BUNDLE" != /* ]]; then
  print -u2 "canonical and Applications bundle paths must be absolute"
  exit 64
fi
CANONICAL_BUILD_BUNDLE="${CANONICAL_BUILD_BUNDLE:A}"
APPLICATION_BUNDLE="${APPLICATION_BUNDLE:A}"

if (( $# > 0 )); then
  SEARCH_ROOTS=("$@")
else
  SEARCH_ROOTS=("$APP_ROOT/.build" "/Applications" "${OUROCODE_AUDIT_TMP_ROOT:-/private/tmp}")
fi

for (( root_index = 1; root_index <= ${#SEARCH_ROOTS[@]}; root_index++ )); do
  SEARCH_ROOTS[$root_index]="${SEARCH_ROOTS[$root_index]:A}"
done

typeset -a rows
typeset -A id_counts
typeset -A id_paths
typeset -A id_channels
found=0

while IFS= read -r -d '' app; do
  plist="$app/Contents/Info.plist"
  [[ -f "$plist" ]] || continue
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || print '?')
  if [[ "$bundle_id" != *ourocode* && "${app:t}" != *Ourocode*.app ]]; then
    continue
  fi
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || print '?')
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || print '?')
  channel=$(/usr/libexec/PlistBuddy -c 'Print :OurocodeBuildChannel' "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :OurocodeBuildProfile' "$plist" 2>/dev/null \
    || print legacy)
  build_id=$(/usr/libexec/PlistBuddy -c 'Print :OurocodeBuildID' "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :OurocodeSourceInputsSHA256' "$plist" 2>/dev/null \
    || print '-')
  executable_path="$app/Contents/MacOS/$executable"
  executable_sha='-'
  if [[ -f "$executable_path" ]]; then
    executable_sha=$(shasum -a 256 "$executable_path" | awk '{print substr($1, 1, 16)}')
  fi
  marker="OK"
  if [[ "$bundle_id" == "$CANONICAL_ID" && "$app" != "$CANONICAL_BUILD_BUNDLE" && "$app" != "$APPLICATION_BUNDLE" ]]; then
    marker="COLLISION: release identifier outside canonical locations"
  elif [[ "$channel" == "development" && "$bundle_id" == "$CANONICAL_ID" ]]; then
    marker="COLLISION: development channel uses release identifier"
  elif [[ "$channel" == "qa" && "$bundle_id" == "$CANONICAL_ID" ]]; then
    marker="COLLISION: QA channel uses release identifier"
  fi
  rows+=("${marker}"$'\t'"${bundle_id}"$'\t'"${channel}"$'\t'"${version}"$'\t'"${build_id}"$'\t'"${executable_sha}"$'\t'"${app}")
  id_counts[$bundle_id]=$(( ${id_counts[$bundle_id]:-0} + 1 ))
  id_paths[$bundle_id]="${id_paths[$bundle_id]:-}"$'\n'"$app"
  id_channels[$bundle_id]="${id_channels[$bundle_id]:-} $channel"
  found=$((found + 1))
done < <(for root in "${SEARCH_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  find -H "$root" -type d -name '*.app' -prune -print0
done)

print $'marker\tbundle_identifier\tchannel\tversion\tbuild_id\texecutable_sha256_prefix\tpath'
for row in ${(o)rows}; do print -r -- "$row"; done

duplicate_count=0
duplicate_nonrelease_count=0
for bundle_id in ${(k)id_counts}; do
  count=${id_counts[$bundle_id]}
  if (( count > 1 )); then
    duplicate_count=$((duplicate_count + 1))
    print -u2 -- "DUPLICATE bundle identifier ($count): $bundle_id${id_paths[$bundle_id]}"
    if [[ "$bundle_id" != "$CANONICAL_ID" ]]; then
      duplicate_nonrelease_count=$((duplicate_nonrelease_count + 1))
    fi
  fi
done

if (( found == 0 )); then
  print -u2 "No application bundles found under the requested roots"
  exit 66
fi

collision_count=0
for row in "${rows[@]}"; do
  [[ "$row" == COLLISION:* ]] && collision_count=$((collision_count + 1))
done

if (( collision_count > 0 || duplicate_nonrelease_count > 0 )); then
  print -u2 "FAIL: $collision_count release identifier collision(s), $duplicate_nonrelease_count duplicated non-release identifier(s); launch by canonical absolute path"
  exit 1
fi
print -u2 "PASS: $found app bundle(s) audited; no release identifier collision"
