#!/bin/sh

set -eu

: "${MACMTP_TEAM_ID:?Set MACMTP_TEAM_ID}"
: "${MACMTP_CODE_SIGN_IDENTITY:?Set MACMTP_CODE_SIGN_IDENTITY}"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$script_directory")
build_directory=${MACMTP_BUILD_DIR:-"$project_directory/build"}
bundle_identifier=${MACMTP_BUNDLE_ID:-com.sudomaker.MacMTP}
app_group=${MACMTP_APP_GROUP:-group.com.sudomaker.MacMTP}
architectures=${MACMTP_ARCHITECTURES:-arm64\;x86_64}

git -C "$project_directory" submodule update --init --recursive
cmake -S "$project_directory" -B "$build_directory" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_OSX_ARCHITECTURES=$architectures" \
  "-DMACMTP_BUNDLE_ID=$bundle_identifier" \
  "-DMACMTP_APP_GROUP=$app_group" \
  "-DMACMTP_TEAM_ID=$MACMTP_TEAM_ID" \
  "-DMACMTP_CODE_SIGN_IDENTITY=$MACMTP_CODE_SIGN_IDENTITY" \
  "$@"
cmake --build "$build_directory"
ctest --test-dir "$build_directory" --output-on-failure
