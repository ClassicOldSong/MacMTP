#!/bin/sh

set -eu

: "${MACMTP_TEAM_ID:?Set MACMTP_TEAM_ID}"
: "${MACMTP_CODE_SIGN_IDENTITY:?Set MACMTP_CODE_SIGN_IDENTITY}"
: "${MACMTP_NOTARY_PROFILE:?Set MACMTP_NOTARY_PROFILE}"
: "${MACMTP_HOMEBREW_RELEASE_URL:?Set MACMTP_HOMEBREW_RELEASE_URL}"
: "${MACMTP_HOMEBREW_HOMEPAGE:?Set MACMTP_HOMEBREW_HOMEPAGE}"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$script_directory")
bundle_identifier=${MACMTP_BUNDLE_ID:-com.sudomaker.MacMTP}
app_group=${MACMTP_APP_GROUP:-group.com.sudomaker.MacMTP}
app_profile=${MACMTP_APP_PROVISIONING_PROFILE:-}
extension_profile=${MACMTP_EXTENSION_PROVISIONING_PROFILE:-}

identity_line=$(/usr/bin/security find-identity -v -p codesigning \
  | /usr/bin/grep -F -- "$MACMTP_CODE_SIGN_IDENTITY" \
  | /usr/bin/head -n 1 || true)
if [ -z "$identity_line" ]; then
  printf 'Signing identity is not installed: %s\n' \
    "$MACMTP_CODE_SIGN_IDENTITY" >&2
  exit 1
fi
case "$identity_line" in
  *'"Developer ID Application:'*) ;;
  *)
    printf 'Release signing requires a Developer ID Application identity.\n' >&2
    exit 1
    ;;
esac

if ! notary_check=$(/usr/bin/xcrun notarytool history \
    --keychain-profile "$MACMTP_NOTARY_PROFILE" \
    --output-format json 2>&1); then
  printf '%s\n' "$notary_check" >&2
  printf 'Unable to use notary credential profile: %s\n' \
    "$MACMTP_NOTARY_PROFILE" >&2
  exit 1
fi

git -C "$project_directory" submodule update --init --recursive
cd "$project_directory"
cmake --preset homebrew-release \
  "-DMACMTP_BUNDLE_ID=$bundle_identifier" \
  "-DMACMTP_APP_GROUP=$app_group" \
  "-DMACMTP_TEAM_ID=$MACMTP_TEAM_ID" \
  "-DMACMTP_CODE_SIGN_IDENTITY=$MACMTP_CODE_SIGN_IDENTITY" \
  "-DMACMTP_APP_PROVISIONING_PROFILE=$app_profile" \
  "-DMACMTP_EXTENSION_PROVISIONING_PROFILE=$extension_profile" \
  "-DMACMTP_NOTARY_PROFILE=$MACMTP_NOTARY_PROFILE" \
  "-DMACMTP_HOMEBREW_RELEASE_URL=$MACMTP_HOMEBREW_RELEASE_URL" \
  "-DMACMTP_HOMEBREW_HOMEPAGE=$MACMTP_HOMEBREW_HOMEPAGE" \
  "$@"
cmake --build --preset homebrew-release
