#!/bin/bash
# Stable-sign one built Mary binary so TCC grants survive rebuilds.
#
# Shared by scripts/dev.sh (terminal builds → .build/…/Mary) and the Xcode
# scheme's LAUNCH PRE-ACTION (DerivedData builds). The point of a STABLE
# certificate: the designated requirement becomes identifier + certificate —
# not the per-build cdhash and not the path — so the .build binary and the
# DerivedData binary satisfy the SAME TCC grant. Grant Accessibility once,
# keep it across rebuilds AND across both launch paths.
#
# Without this, SwiftPM's own signing step signs AD-HOC (`codesign --sign -`),
# whose identity IS the cdhash and therefore changes every build. macOS then
# treats each rebuild as a brand-new app: the System Settings checkbox still
# LOOKS enabled while AXIsProcessTrusted() quietly returns false.
#
#   ./scripts/sign-binary.sh /path/to/Mary
#
BIN="$1"

if [ ! -f "$BIN" ]; then
    echo "sign-binary: nothing at $BIN — skipping"
    exit 0
fi

# Prefer an Apple Development identity; fall back to a self-made
# "Mary Dev Signing" cert (Keychain Access → Certificate Assistant →
# Create a Certificate → Code Signing, if you have neither).
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
