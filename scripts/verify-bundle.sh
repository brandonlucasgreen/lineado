#!/bin/bash
#
# Audit a built .app for the things no build failure would ever reveal.
#
# This exists because of three traps inherited from Inbox & Chill, every one of
# which ships a working-looking bundle:
#
#   1. INFOPLIST_KEY_SUFeedURL does nothing. Xcode only synthesises
#      INFOPLIST_KEY_* for keys it already knows, and SUFeedURL is not one of
#      them. I&C shipped a bundle with no feed URL and nothing warned — the app
#      simply never found an update, for anyone, silently.
#   2. Xcode leaves Sparkle's nested helpers ad-hoc signed. That fails
#      notarization, and only notarization tells you.
#   3. LSUIElement missing turns a menu bar app into a Dock app at launch.
#
# Add a check here whenever you add a plist key something reads at runtime.
#
# Usage: scripts/verify-bundle.sh [path/to/Lineado.app]
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Release/Build/Products/Release/Lineado.app}"
PLIST="$APP/Contents/Info.plist"
FAILED=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
note() { printf '  \033[33m•\033[0m %s\n' "$1"; }

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
echo "Auditing $APP"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

echo
echo "Info.plist"

for key in CFBundleIdentifier CFBundleName CFBundleShortVersionString CFBundleVersion; do
  value="$(plist_value "$key")"
  if [ -n "$value" ]; then pass "$key = $value"; else fail "$key is missing"; fi
done

bundle_id="$(plist_value CFBundleIdentifier)"
if [ "$bundle_id" = "lol.bgreen.lineado" ]; then
  pass "bundle id is lol.bgreen.lineado"
else
  fail "bundle id is '$bundle_id', expected lol.bgreen.lineado"
fi

# Trap 3: a menu bar app without this gets a Dock icon and a ⌘Tab entry.
if [ "$(plist_value LSUIElement)" = "true" ]; then
  pass "LSUIElement is true (no Dock icon)"
else
  fail "LSUIElement is not true — this would launch as a Dock app"
fi

# Trap 1: the whole reason this script exists.
feed="$(plist_value SUFeedURL)"
case "$feed" in
  https://*)
    pass "SUFeedURL = $feed"
    ;;
  "")
    fail "SUFeedURL is EMPTY — updates can never be found (see trap 1 above)"
    ;;
  *)
    fail "SUFeedURL is not https: '$feed'"
    ;;
esac

# Trap 3's quieter cousin: a build with no key cannot verify an update. That is
# correct for a local build, so it is a note, not a failure — but a release
# build without it would ship an updater that refuses every update silently.
ed_key="$(plist_value SUPublicEDKey)"
if [ -n "$ed_key" ]; then
  pass "SUPublicEDKey present (${#ed_key} chars)"
else
  note "SUPublicEDKey is empty — fine locally, FATAL for a release. Run scripts/sparkle-keys.sh"
fi

echo
echo "Code signature"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  pass "codesign --verify --deep --strict"
else
  fail "deep signature verification failed (trap 2: a nested ad-hoc signature?)"
fi

authority="$(codesign -dv --verbose=2 "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2- || true)"
case "$authority" in
  "Developer ID Application:"*)
    pass "signed with $authority"
    ;;
  "")
    note "unsigned or ad-hoc — fine for a local debug build, never for a release"
    ;;
  *)
    note "signed by $authority (not Developer ID)"
    ;;
esac

# Trap 2: each nested executable must carry the same signature as the app.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  pass "Sparkle.framework is embedded"
  while IFS= read -r helper; do
    [ -n "$helper" ] || continue
    if codesign --verify --strict "$helper" 2>/dev/null; then
      pass "  nested: $(basename "$helper") verifies"
    else
      fail "  nested: $(basename "$helper") FAILS — would fail notarization"
    fi
  done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \
             \( -name "*.app" -o -name "*.xpc" \) -maxdepth 3 2>/dev/null)
else
  fail "Sparkle.framework is not embedded — in-app updates cannot work"
fi

echo
echo "Hardened runtime"

# Capture first, match second. `set -o pipefail` plus `grep -q` is a trap:
# grep exits the moment it matches, codesign takes SIGPIPE on the next write,
# and the pipeline reports the producer's failure however well the match went.
# That made this check report "not enabled" on a bundle that plainly was, and
# made the entitlements check below it a coin flip that happened to land right.
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if printf '%s' "$entitlements" | grep -q "network.client"; then
  pass "network.client entitlement present"
else
  fail "network.client entitlement missing — every Linear request would fail"
fi

signature="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
if printf '%s' "$signature" | grep -q "flags=.*runtime"; then
  pass "hardened runtime enabled"
else
  note "hardened runtime not enabled — required for notarization"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mBundle audit passed.\033[0m\n'
else
  printf '\033[31mBundle audit FAILED.\033[0m\n' >&2
  exit 1
fi
