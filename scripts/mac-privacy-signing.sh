#!/usr/bin/env bash
# Sourced by build-app.sh; SIGN is its already-scoped codesign argument array.
# The requirement is certificate-renewal safe, but restricted to our Developer ID team.
td_privacy_requirement() {
  printf 'identifier "%s" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "6U4VNX5W87"' "$1"
}

td_sign_privacy_helper() {
  local executable="$1" identifier="$2" entitlements="$3" requirement
  case "$identifier" in
    ''|*[!A-Za-z0-9.-]*) echo 'error: invalid keeper signing identifier' >&2; return 1 ;;
  esac
  requirement="$(td_privacy_requirement "$identifier")"
  if [ "$IDENTITY" = "-" ]; then
    # Ad-hoc builds deliberately retain hash-based identity. They cannot prove persistence of grants.
    "${SIGN[@]}" --identifier "$identifier" --entitlements "$entitlements" "$executable"
  else
    "${SIGN[@]}" --identifier "$identifier" --requirements "=designated => $requirement" --entitlements "$entitlements" "$executable"
    # Fail closed for the wrong team, missing Developer ID chain, or changed identifier.
    codesign --verify --strict "-R=$requirement" "$executable"
  fi
}
