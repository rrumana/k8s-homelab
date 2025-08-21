#!/usr/bin/env bash
# Extract an entire Borg archive to a local folder, preserving original directory structure.
# This is a "full dump" so you can manually search and recover what you need.
#
# Usage:
#   export BORG_REPO=/media/backup/borg
#   export BORG_PASSPHRASE='your-passphrase'
#   ARCHIVE=20250814_040054-nextcloud-aio TARGET="$HOME/Borg_Full_Extract/20250814_040054-nextcloud-aio" ./export_whole_archive.sh
#
# Notes:
# - Requires local 'borg' (and sudo if your repo requires root-owned lock files).
# - TARGET will be created if it does not exist. Extraction preserves the archive's paths (no stripping).
# - This can be large; ensure you have enough free disk space.

set -euo pipefail

: "${BORG_REPO:?Set BORG_REPO to your repo path, e.g. /media/backup/borg}"
: "${BORG_PASSPHRASE:?Set BORG_PASSPHRASE to unlock the repo}"

ARCHIVE="${ARCHIVE:-${1:-}}"
if [[ -z "${ARCHIVE}" ]]; then
  echo "ERROR: Provide ARCHIVE via env or arg (e.g. ARCHIVE=20250814_040054-nextcloud-aio)"
  exit 1
fi

# Default target if not provided
TARGET="${TARGET:-${HOME}/Borg_Full_Extract/${ARCHIVE}}"
mkdir -p "${TARGET}"

# Use sudo -E to preserve env (BORG_*), required when repo needs root to write lock file
SUDO="sudo -E"

echo "Repo   : ${BORG_REPO}"
echo "Archive: ${ARCHIVE}"
echo "Target : ${TARGET}"
echo

# Show archive info and a quick sample of paths
echo "=== Archive info ==="
${SUDO} borg info "${BORG_REPO}::${ARCHIVE}" || true
echo
echo "Sample of top-level entries:"
${SUDO} borg list "${BORG_REPO}::${ARCHIVE}" | sed -n '1,50p' || true
echo

# Confirm and extract
echo "Extracting full archive to: ${TARGET}"
echo "(This may take a while and use significant space.)"
cd "${TARGET}"
${SUDO} borg extract --progress "${BORG_REPO}::${ARCHIVE}"

echo
echo "Done. Top-level of ${TARGET}:"
ls -la "${TARGET}" | sed -n '1,200p"

echo
echo "Hints for Nextcloud AIO archives:"
echo "  - Look under nextcloud_aio_volumes/ for data, DB, etc."
echo "  - Typical user file paths:"
echo "      nextcloud_aio_volumes/nextcloud_aio_nextcloud_data/data/<user>/files/"
echo "  - Search for likely markers:"
echo "      find \"${TARGET}\" -maxdepth 5 -type f -name config.php -o -name nextcloud.log 2>/dev/null | head -n 20"
echo "      find \"${TARGET}\" -maxdepth 4 -type d -name files 2>/dev/null | head -n 20"
echo
echo "You can now manually browse ${TARGET}, copy out what you need, or re-upload via Web UI or WebDAV."