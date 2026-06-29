#!/usr/bin/env bash
# Check build-args conf files for non-stable (EA or "fast") image version
# references. Stable builds must never reference non-stable image versions.
#
# Usage:
#   check-build-args.sh file1.conf [file2.conf ...]
#
# Environment variables:
#   VERSION_KEY  - Key name to read from each conf file
#                  (e.g. "RHAIIS_VERSION" or "RHELAI_VERSION_ID").
#                  Serves two purposes:
#                  1. Identifies container build configs — files
#                     without this key are skipped (e.g. disk image
#                     or cloud argfiles that reference already-built
#                     artifacts by digest).
#                  2. Provides branch-awareness — if the value
#                     contains "-EA" or "-fast" (case-insensitive),
#                     non-stable image refs are expected and the
#                     check is skipped for that file.
#                  If unset, all files are checked unconditionally.
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 file1.conf [file2.conf ...]"
    exit 1
fi

fail=0

for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "WARNING: $file not found, skipping."
        continue
    fi

    if [ -n "${VERSION_KEY:-}" ]; then
        version=$(grep "^${VERSION_KEY}=" "$file" | head -1 | cut -d= -f2 || true)
        if [ -z "$version" ]; then
            echo "SKIP: $file (no $VERSION_KEY, not a container build config)"
            continue
        fi
        version_upper=$(echo "$version" | tr '[:lower:]' '[:upper:]')
        if [[ "$version_upper" == *-EA* ]] || [[ "$version_upper" == *-FAST* ]]; then
            echo "OK: $file ($VERSION_KEY=$version is non-stable, skipping check)"
            continue
        fi
    fi

    matches=$(grep -inE '^[A-Za-z0-9_]+=.*(-ea\.|-fast\.)' "$file" || true)
    if [ -n "$matches" ]; then
        echo "ERROR: Non-stable version references in $file:"
        echo "$matches"
        fail=1
    else
        echo "OK: $file"
    fi
done

exit $fail
