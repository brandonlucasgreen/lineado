#!/bin/bash
#
# ONE TIME: create the Sparkle update-signing key pair.
#
# The private key goes into your **login keychain** and never touches the repo.
# The public key goes into project.yml as SUPublicEDKey, which is committed.
#
# Three things worth knowing before you run this:
#
#   1. Losing the private key means you can never ship an update to an existing
#      install again. Every user would have to download the app by hand. Back up
#      the keychain item.
#   2. An unsigned appcast entry looks exactly like a working one. The updater
#      simply refuses it, silently. scripts/appcast.sh signs every entry; do not
#      hand-edit appcast.xml.
#   3. A build with an empty SUPublicEDKey can never install an update. That is
#      correct for local builds — Settings says so — but fatal in a release, and
#      scripts/verify-bundle.sh notes it.
#
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/sparkle-tools.sh

TOOLS=".sparkle/bin"
[ -x "$TOOLS/generate_keys" ] || { echo "error: no generate_keys in $TOOLS" >&2; exit 1; }

if grep -q 'SUPublicEDKey: "[^"]\+"' project.yml; then
  echo "project.yml already has a SUPublicEDKey."
  echo "Generating another key would strand every existing install."
  echo "Delete the line by hand first if you really mean to rotate it."
  exit 1
fi

echo "Generating a key pair. The private half goes to your login keychain."
"$TOOLS/generate_keys"

echo
echo "Now copy the public key printed above into project.yml:"
echo "    SUPublicEDKey: \"<the key>\""
echo "then run: xcodegen generate && scripts/verify-bundle.sh"
