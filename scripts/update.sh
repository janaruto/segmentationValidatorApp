#!/bin/bash
# Updates your copy of the app to the newest version on GitHub. Afterwards press ▶︎ in Xcode.
#
# Keeps what you chose in Xcode under Signing & Capabilities (team and bundle identifier).
# Everything else that changed locally is replaced by the GitHub version: Xcode edits some
# files by itself while building (e.g. the string catalogs), and that would block `git pull`.
#
# Usage: scripts/update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

project="SegmentationValidator.xcodeproj/project.pbxproj"

# Prints the first value of a build setting in the project file, e.g. DEVELOPMENT_TEAM.
setting() {
    NAME="$1" perl -ne 'if (/\b\Q$ENV{NAME}\E = ([^;]*);/) { print "$1\n"; exit }' "$project"
}

# Writes a value back into every occurrence of a build setting.
restore() {
    if [ -n "$2" ] && [ "$2" != '""' ]; then
        NAME="$1" VALUE="$2" perl -pi -e 's/\b\Q$ENV{NAME}\E = [^;]*;/$ENV{NAME} = $ENV{VALUE};/' "$project"
    fi
}

team=$(setting DEVELOPMENT_TEAM)
bundle=$(setting PRODUCT_BUNDLE_IDENTIFIER)

git fetch --quiet origin main
git reset --quiet --hard origin/main

restore DEVELOPMENT_TEAM "$team"
restore PRODUCT_BUNDLE_IDENTIFIER "$bundle"

echo "Updated to: $(git log -1 --format='%h %s')"
if [ -n "$team" ] && [ "$team" != '""' ]; then
    echo "Kept your signing team ($team) and bundle identifier ($bundle)."
else
    echo "No signing team set yet: choose it in Xcode under Signing & Capabilities."
fi
echo "Now press ▶︎ in Xcode."
