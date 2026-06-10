#!/bin/bash
set -euo pipefail

# Copy nvbeacon.* preference keys into the app's domain (com.timkoopmans.beacon)
# from the newest legacy domain: upstream main (com.leejaein.NVBeacon) or any
# test-bundle domain (*.test.<sha>). One-shot: skips if the target domain is
# already configured, so a redeploy never clobbers live settings. FORCE=1 to
# re-run anyway.

MAIN_DOMAIN="com.timkoopmans.beacon"
PREFS_DIR="$HOME/Library/Preferences"
FORCE="${FORCE:-0}"

if [[ "$FORCE" != "1" ]] && defaults read "$MAIN_DOMAIN" nvbeacon.settings >/dev/null 2>&1; then
  echo "$MAIN_DOMAIN already configured; skipping migration (FORCE=1 to override)."
  exit 0
fi

SOURCE_PLIST="$(ls -t \
  "$PREFS_DIR/$MAIN_DOMAIN".test.*.plist \
  "$PREFS_DIR/com.leejaein.NVBeacon".test.*.plist \
  "$PREFS_DIR/com.leejaein.NVBeacon.plist" \
  2>/dev/null | head -n 1 || true)"
if [[ -z "$SOURCE_PLIST" ]]; then
  echo "No legacy preferences found; nothing to migrate."
  exit 0
fi
SOURCE_DOMAIN="$(basename "$SOURCE_PLIST" .plist)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

defaults export "$SOURCE_DOMAIN" "$TMP_DIR/source.plist"
if ! defaults export "$MAIN_DOMAIN" "$TMP_DIR/main.plist" 2>/dev/null; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$TMP_DIR/main.plist"
fi

python3 - "$TMP_DIR/source.plist" "$TMP_DIR/main.plist" <<'PY'
import plistlib, sys

source_path, main_path = sys.argv[1], sys.argv[2]
with open(source_path, "rb") as f:
    source = plistlib.load(f)
with open(main_path, "rb") as f:
    main = plistlib.load(f)

migrated = [k for k in source if k.startswith("nvbeacon.")]
for key in migrated:
    main[key] = source[key]

with open(main_path, "wb") as f:
    plistlib.dump(main, f, fmt=plistlib.FMT_BINARY)

print("Migrated keys:", ", ".join(migrated) if migrated else "(none)")
PY

defaults import "$MAIN_DOMAIN" "$TMP_DIR/main.plist"
echo "Migrated $SOURCE_DOMAIN -> $MAIN_DOMAIN"
