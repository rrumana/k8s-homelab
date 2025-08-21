#!/usr/bin/env bash
# Export per-user Nextcloud files from a Borg AIO or non-AIO archive to a local folder
# for manual review/re-upload. Robust against AIO layouts under nextcloud_aio_volumes.
#
# Usage:
#   export BORG_REPO=/media/backup/borg
#   export BORG_PASSPHRASE='your-passphrase'
#   ARCHIVE=20250814_040054-nextcloud-aio TARGET="$HOME/Nextcloud_Restore" ./export_users_from_borg.sh
#
# Notes:
# - Requires local 'borg' and 'tar'.
# - Exports only .../data/<user>/files content. Skips DB, previews, trashbin, versions, appdata_*.
# - Creates per-user folders under $TARGET/<user> with their file contents.

set -euo pipefail

# --- Configuration from env/args ---
: "${BORG_REPO:?Set BORG_REPO to your repo path, e.g. /media/backup/borg}"
: "${BORG_PASSPHRASE:?Set BORG_PASSPHRASE to unlock the repo}"

ARCHIVE="${ARCHIVE:-${1:-}}"
if [[ -z "${ARCHIVE}" ]]; then
  echo "ERROR: Provide ARCHIVE via env or arg (e.g. ARCHIVE=20250814_040054-nextcloud-aio)"
  exit 1
fi

TARGET="${TARGET:-${HOME}/Nextcloud_Restore}"
mkdir -p "${TARGET}"

# Use sudo -E to ensure repo lock can be created if repo owned by root or on RW mount requiring elevated perms
SUDO="sudo -E"

echo "Repo: ${BORG_REPO}"
echo "Archive: ${ARCHIVE}"
echo "Target: ${TARGET}"
echo

# --- Detect data roots in AIO/non-AIO archives (path-driven, strict) ---
# Strategy:
# - Get path-only entries with borg list --short
# - Find paths that end exactly with .../data/<user>/files (directory marker)
# - Exclude known non-user pseudo-dirs (appdata*, files_trashbin, files_versions, etc.)
echo "Detecting data roots (supports Nextcloud AIO layouts)..."
SHORT_LIST="$(${SUDO} borg list --short "${BORG_REPO}::${ARCHIVE}")"

RESERVED_REGEX='^(apps|templates|circles|files_trashbin|files_versions|specs|appdata.*|\.ocdata|\.{1,2}|data)$'

# Build a map: user<TAB>files_dir_path<TAB>strip_components
# Accept only paths that are exactly .../data/<user>/files (directory)
MAP="$(printf "%s\n" "${SHORT_LIST}" | awk -F'/' '
{
  n=split($0,a,"/");
  for (i=1; i<=n-2; i++) {
    if (a[i]=="data" && a[i+2]=="files") {
      user=a[i+1];
      if (user=="" || user=="." || user==".." || user=="data") { next }
      # reconstruct the exact path up to .../files
      p=a[1];
      for (j=2; j<=i+2; j++) { p=p "/" a[j]; }
      strip=i+2; # drop everything up to and including files
      print user "\t" p "\t" strip;
      break;
    }
  }
}' | awk -F'\t' -v rx="${RESERVED_REGEX}" '
  $1 !~ rx { if (!seen[$1]++) print $0 }
')"

if [[ -z "${MAP}" ]]; then
  echo "Could not locate any '/data/<user>/files' directories in archive '${ARCHIVE}'."
  echo
  echo "Archive sample (first 200 entries):"
  ${SUDO} borg list "${BORG_REPO}::${ARCHIVE}" | sed -n '1,200p'
  echo
  echo "Hint: For Nextcloud AIO, user files usually live under:"
  echo "  nextcloud_aio_volumes/nextcloud_aio_nextcloud_data/data/<user>/files"
  exit 1
fi

echo "Found users and paths:"
echo "${MAP}" | awk -F $'\t' '{printf "  - %s  (%s)\n", $1, $2}'
echo

# --- Export each user's files into TARGET/<user> ---
echo "Exporting per-user files..."
# Iterate over map lines: user \t files_dir_path \t strip
while IFS=$'\t' read -r U P STRIP; do
  [ -n "${U}" ] || continue
  [ -n "${P}" ] || continue
  [ -n "${STRIP}" ] || continue
  echo "User: ${U}"
  mkdir -p "${TARGET}/${U}"
  # Export the directory tree under /files by appending a trailing slash.
  # If borg complains the exact dir path does not exist, try without slash as a fallback.
  if ! ${SUDO} borg export-tar "${BORG_REPO}::${ARCHIVE}" "${P}/" - \
      | tar -x --strip-components="${STRIP}" -C "${TARGET}/${U}" 2>/dev/null; then
    echo "  Retrying without trailing slash for ${P}"
    ${SUDO} borg export-tar "${BORG_REPO}::${ARCHIVE}" "${P}" - \
      | tar -x --strip-components="${STRIP}" -C "${TARGET}/${U}" 2>/dev/null
  fi
done <<< "${MAP}"

echo
echo "Done. Per-user files extracted under: ${TARGET}"
echo "Example listing:"
ls -la "${TARGET}" | sed -n '1,200p'

echo
echo "Next steps:"
echo "  - Review files locally in ${TARGET}."
echo "  - Manually re-upload desired content to Nextcloud (Web UI or WebDAV)."
echo "  - Optional: remove AIO-specific bulk from the Kubernetes PVC (previews/versions/trashbin) as previously noted."