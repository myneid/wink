#!/bin/bash
# The database bridge is shared, verbatim, with Blink's Apps host. Wink holds
# the originals; this copies them into a Blink checkout, or with --check
# reports whether the copies match.
#   tools/sync-blink-database.sh ../blink            # copy
#   tools/sync-blink-database.sh ../blink --check    # verify only
set -euo pipefail
cd "$(dirname "$0")/.."
BLINK=${1:?usage: $0 path/to/blink [--check]}
FILES=(DatabaseURL.swift MySQLClient.swift DatabaseBridge.swift)
status=0
for f in "${FILES[@]}"; do
  if [[ "${2:-}" == "--check" ]]; then
    if cmp -s "Sources/$f" "$BLINK/Blink/Database/$f"; then echo "same: $f"; else echo "DIFFERS: $f"; status=1; fi
  else
    mkdir -p "$BLINK/Blink/Database"
    cp "Sources/$f" "$BLINK/Blink/Database/$f"
    echo "copied: $f"
  fi
done
exit $status
