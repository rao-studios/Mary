#!/bin/bash
# WHAT: Stable-sign one built Mary binary so TCC grants survive rebuilds.
# IN:   path to binary — scripts/dev.sh and the Xcode launch pre-action.
# PIN:  Designated requirement = identifier + certificate, not per-build
#       cdhash. Ad-hoc identity IS the cdhash; AXIsProcessTrusted goes false
#       while System Settings still looks enabled.
#
#   ./scripts/sign-binary.sh /path/to/Mary
#
BIN="$1"

if [ ! -f "$BIN" ]; then
    echo "sign-binary: nothing at $BIN — skipping"
    exit 0
fi

# Prefer Apple Development; else Keychain "Mary Dev Signing" (Code Signing).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Mary Dev Signing/ {print $2; exit}')"

if [ -z "$IDENTITY" ]; then
    echo "sign-binary: WARNING — no stable codesigning identity; leaving ad-hoc."
    echo "  TCC grants (Accessibility etc.) will NOT survive the next build."
    exit 0
fi

# --preserve-metadata keeps get-task-allow so the debugger still attaches.
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$BIN"
echo "sign-binary: signed $BIN with '$IDENTITY'"
