#!/usr/bin/env bash
# The release notes for a version, exactly as release.yml publishes them: the
# version's CHANGELOG.md section, then what every release has to tell a new
# user (docs/RELEASING.md), then the DMG's SHA-256.
#
#   bash scripts/release_notes.sh [version] [dmg]
#       defaults: the VERSION file, and build/Ext4Mac-<version>.dmg
#   make release-notes
#
# Its own script so the text can be read before a tag publishes it:
# check_release.sh builds it on every `make release`, and ci_release.sh
# publishes what it prints. While it lived inside ci_release.sh, the first
# time anyone saw it was on the release page -- and it was still telling
# people "macOS 15.4 or later" for a release that required 26.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="${1:-$(tr -d '[:space:]' < VERSION)}"
dmg="${2:-build/Ext4Mac-$version.dmg}"
blob="https://github.com/h3ct0r/open_ext4_for_mac/blob/v$version"

section="$(awk -v v="$version" '$0 ~ "^## \\["v"\\]"{p=1; next} /^## \[/{p=0} p' CHANGELOG.md)"
[ -n "$section" ] || { echo "release_notes: CHANGELOG.md has no [$version] section" >&2; exit 1; }
[ -f "$dmg" ] || { echo "release_notes: no $dmg; make dmg first" >&2; exit 1; }
# The floor the built app declares, not a number typed in here.
floor="$(plutil -extract LSMinimumSystemVersion raw -o - build/Ext4Mac.app/Contents/Info.plist)"
sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

# A relative link resolves in CHANGELOG.md on GitHub, but a release page
# resolves it against /releases/tag/, where there is nothing: point it at the
# file as tagged.
printf '%s\n' "$section" | sed -E "s|]\(/?([^):#]+)([)#])|](${blob}/\1\2|g"
cat <<EOF

---

**Eject before unplugging.** FSKit gives this driver no way to flush a drive's cache, so the journal's ordering guarantee stops at the drive. Twenty mid-write pulls across five drives recovered cleanly, but a pull mid-write can also panic macOS itself. What was measured: [docs/ENVELOPE.md]($blob/docs/ENVELOPE.md#the-barrier-what-this-driver-cannot-promise).

**After installing or upgrading, approve the extension** in System Settings → General → Login Items & Extensions → File System Extensions. macOS grants this by hand only. Step by step, with what to do when it looks broken: [docs/INSTALL.md]($blob/docs/INSTALL.md).

**Known limitations** — what is refused, read-only, and not yet done: [docs/ENVELOPE.md]($blob/docs/ENVELOPE.md). Apple Silicon and macOS ${floor%.0} or later only.

\`$(basename "$dmg")\` SHA-256: \`$sha\`
EOF
