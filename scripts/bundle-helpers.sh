#!/bin/zsh
# Copies ffmpeg, ffprobe, and cdparanoia into Contents/Helpers.
# Prefer static/universal binaries placed in $SRCROOT/Helpers.
# Homebrew copies are a local-dev fallback and are not relocatable for distribution.
set -euo pipefail

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
  echo "This script is meant to run as an Xcode Run Script build phase."
  exit 0
fi

DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "${DEST}"
HELPERS="${SRCROOT}/Helpers"

copy_one() {
  local name="$1"
  if [[ -x "${HELPERS}/${name}" ]]; then
    cp -f "${HELPERS}/${name}" "${DEST}/${name}"
    echo "Bundled Helpers/${name} from project Helpers/"
    return 0
  fi
  for prefix in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
    if [[ -x "${prefix}/${name}" ]]; then
      echo "warning: ${name} copied from ${prefix}. Homebrew binaries link into Cellar and will not survive notarized distribution. Put a static universal build in Helpers/${name}."
      cp -f "${prefix}/${name}" "${DEST}/${name}" || true
      return 0
    fi
  done
  echo "note: ${name} not found. Export/rip will look on PATH at runtime. See README."
}

copy_one ffmpeg
copy_one ffprobe
copy_one cdparanoia
copy_one cd-paranoia
exit 0
