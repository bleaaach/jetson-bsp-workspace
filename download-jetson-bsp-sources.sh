#!/usr/bin/env bash
# Download an official Jetson Linux BSP source bundle for a requested release.
set -euo pipefail

archive_url="https://developer.nvidia.com/embedded/jetson-linux-archive"
site_url="https://developer.nvidia.com"
workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry_run=0

usage() {
    echo "Usage: $(basename "$0") [--dry-run] R<major>.<minor>.<patch>"
    echo "Example: $(basename "$0") R36.4.4"
}

if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

release="${1#R}"
if [[ ! "${release}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release must use the form R36.4.4 or 36.4.4." >&2
    exit 2
fi
release_token="R${release}"
release_pattern="${release//./\\.}"

archive_html="$(mktemp)"
release_html="$(mktemp)"
trap 'rm -f "${archive_html}" "${release_html}"' EXIT

curl -fsSL --retry 3 "${archive_url}" -o "${archive_html}"
release_href="$(sed -nE "/>[[:space:]]*${release_pattern}[[:space:]]*&gt;/ { s/.*href=\"([^\"]+)\".*/\1/p; q; }" "${archive_html}")"

if [[ -z "${release_href}" ]]; then
    echo "${release_token} was not found in the official Jetson Linux archive." >&2
    exit 1
fi

case "${release_href}" in
    http://*|https://*) release_page="${release_href}" ;;
    *) release_page="${site_url}${release_href}" ;;
esac

curl -fsSL --retry 3 "${release_page}" -o "${release_html}"
source_url="$(sed -nE '/Driver Package \(BSP\) Sources/ { s/.*href="([^"]+)".*/\1/p; q; }' "${release_html}")"

if [[ -z "${source_url}" ]]; then
    echo "No Driver Package (BSP) Sources link was found on ${release_page}." >&2
    exit 1
fi

destination_dir="${workspace_dir}/Downloads/${release_token}"
destination="${destination_dir}/public_sources.tbz2"
temporary="${destination}.part"

is_valid_archive() {
    local archive_type
    archive_type="$(file -b "$1")"
    [[ -s "$1" && "${archive_type}" == *"bzip2 compressed"* ]] && tar -tjf "$1" >/dev/null
}

echo "Release: ${release_token}"
echo "Release page: ${release_page}"
echo "BSP sources: ${source_url}"
echo "Destination: ${destination}"

if (( dry_run )); then
    exit 0
fi

mkdir -p "${destination_dir}"
if [[ -e "${destination}" ]]; then
    if is_valid_archive "${destination}"; then
        echo "Reusing validated archive."
        exit 0
    fi
    echo "Existing file is not a valid bzip2 tar archive: ${destination}" >&2
    exit 1
fi

available_bytes="$(df -PB1 "${workspace_dir}" | awk 'NR == 2 { print $4 }')"
content_length="$(curl -fsIL --retry 3 "${source_url}" | awk 'BEGIN { IGNORECASE = 1 } /^content-length:/ { value = $2 } END { gsub("\\r", "", value); print value }')"
if [[ ! "${content_length}" =~ ^[0-9]+$ ]]; then
    echo "Could not determine the source archive size." >&2
    exit 1
fi

if (( available_bytes < content_length * 12 / 10 )); then
    echo "Insufficient free disk space for the source archive." >&2
    exit 1
fi

rm -f "${temporary}"
trap 'rm -f "${archive_html}" "${release_html}" "${temporary}"' EXIT
curl -fL --retry 3 --retry-delay 5 -o "${temporary}" "${source_url}"
if ! is_valid_archive "${temporary}"; then
    echo "Downloaded file failed bzip2/tar validation." >&2
    exit 1
fi

mv "${temporary}" "${destination}"
echo "Validated BSP sources: ${destination}"
