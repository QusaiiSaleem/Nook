#!/bin/bash
# Fork/update-wa-js.sh: vendor WPPConnect WA-JS (Apache-2.0), which the local WhatsApp copy runs
# inside WhatsApp Web to read messages.
#
#   Fork/update-wa-js.sh            -> download the pinned version, check its SHA-256, install it
#   Fork/update-wa-js.sh v4.8.0     -> download another release and print its SHA-256 to pin
#
# Updating is deliberate: when WhatsApp changes and the copy pauses, check the WA-JS releases,
# run this with the new tag, review, then pin the new tag and hash below.
set -euo pipefail

PINNED_TAG="v4.7.2"
PINNED_SHA256="97aca719c9ef8e618e7941425920451139def9bd70f5d8449c24864f406dfc85"

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$SRC/Nook/Managers/MessageArchive"
TAG="${1:-$PINNED_TAG}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh release download "$TAG" --repo wppconnect-team/wa-js --pattern wppconnect-wa.js --dir "$WORK"
gh api "repos/wppconnect-team/wa-js/contents/LICENSE?ref=$TAG" --jq .content | base64 -d > "$WORK/LICENSE"

SHA="$(shasum -a 256 "$WORK/wppconnect-wa.js" | cut -d' ' -f1)"
echo "WA-JS $TAG: $(wc -c < "$WORK/wppconnect-wa.js" | tr -d ' ') bytes, SHA-256 $SHA"

if [ "$TAG" = "$PINNED_TAG" ] && [ "$PINNED_SHA256" != "__SET_ON_FIRST_RUN__" ] && [ "$SHA" != "$PINNED_SHA256" ]; then
  echo "SHA-256 does not match the pinned $PINNED_SHA256. Nothing installed." >&2
  exit 1
fi
if [ "$TAG" != "$PINNED_TAG" ]; then
  echo "Not the pinned tag: review it, then set PINNED_TAG=$TAG and PINNED_SHA256=$SHA in this script and run it again." >&2
  exit 1
fi

cp "$WORK/wppconnect-wa.js" "$DEST/wppconnect-wa.js"
{ echo "WPPConnect WA-JS $TAG (https://github.com/wppconnect-team/wa-js), bundled as wppconnect-wa.js."; echo; cat "$WORK/LICENSE"; } > "$DEST/WA-JS-LICENSE.txt"
echo "Installed $DEST/wppconnect-wa.js"
