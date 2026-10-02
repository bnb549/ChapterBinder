#!/bin/zsh
# Copies static ffmpeg, ffprobe, and cdparanoia from $SRCROOT/Helpers
# into Contents/Helpers. Missing binaries are optional. Homebrew is not copied.
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
    echo "Bundled Helpers/${name}"
    return 0
  fi
  echo "note: ${name} is not in Helpers/. The direct-download build still exports without it."
}

copy_one ffmpeg
copy_one ffprobe
copy_one cdparanoia
copy_one cd-paranoia
exit 0
