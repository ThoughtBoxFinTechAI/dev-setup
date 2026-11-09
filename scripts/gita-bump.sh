#!/usr/bin/env bash
# Updates the Gita version and checksums pinned in install.sh and install.ps1
# to the latest published (not draft, not pre-release) Gita release, after
# checking every download against the release's SHA256SUMS and starting the
# Linux build once. Used by .github/workflows/gita-bump.yml; can be run by hand.
#
#   scripts/gita-bump.sh            # needs gh (signed in, or GH_TOKEN), curl, sha256sum, tar
#
# Prints "version=<v>" and "changed=true|false" (also to $GITHUB_OUTPUT when set).
# Exits non-zero, changing nothing, if anything doesn't check out.
set -euo pipefail

REPO=${GITA_REPO_OVERRIDE:-naseebnaushad/gita}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH="$ROOT/install.sh"
PS="$ROOT/install.ps1"

output() { echo "$1"; if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi; }
fail() { echo "gita-bump: $1" >&2; exit 1; }

# 1.2.10 > 1.2.9; a "-suffix" (pre-release) is ignored for ordering.
newer() { # newer A B: is A newer than B?
  local a=${1%%-*} b=${2%%-*} i x y
  IFS=. read -r -a A <<<"$a"
  IFS=. read -r -a B <<<"$b"
  for i in 0 1 2; do
    x=${A[i]:-0}; y=${B[i]:-0}
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

current=$(sed -n 's/^ *local GITA_VERSION="\([^"]*\)".*/\1/p' "$SH" | head -1)
[ -n "$current" ] || fail "couldn't find GITA_VERSION in install.sh"
current_ps=$(sed -n "s/^ *\$GitaVersion *= *'\([^']*\)'.*/\1/p" "$PS" | head -1)
[ "$current" = "$current_ps" ] || fail "install.sh ($current) and install.ps1 ($current_ps) pin different versions"

# "gh release view" without a tag is GitHub's Latest release: published,
# never a draft or a pre-release.
tag=$(gh release view --repo "$REPO" --json tagName --jq .tagName)
latest=${tag#v}
[[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "latest release tag \"$tag\" isn't vX.Y.Z"

output "version=$latest"
if ! newer "$latest" "$current"; then
  echo "Pinned Gita $current is up to date (latest release: $latest)."
  output "changed=false"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
assets=(gita-windows-x64.zip gita-macos.zip gita-linux-x64.tar.gz)
gh release download "$tag" --repo "$REPO" --dir "$work" \
  --pattern SHA256SUMS --pattern "${assets[0]}" --pattern "${assets[1]}" --pattern "${assets[2]}"

[ -f "$work/SHA256SUMS" ] || fail "release $tag has no SHA256SUMS"
sum_of() { awk -v f="$1" '$2 == f || $2 == "*"f {print $1}' "$work/SHA256SUMS" | head -1; }
declare -A sha
for a in "${assets[@]}"; do
  [ -f "$work/$a" ] || fail "release $tag has no $a"
  want=$(sum_of "$a")
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || fail "SHA256SUMS has no checksum for $a"
  got=$(sha256sum "$work/$a" | cut -d' ' -f1)
  [ "$got" = "$want" ] || fail "$a doesn't match SHA256SUMS (got $got, expected $want)"
  sha[$a]=$got
done

# Start the Linux build once: a release whose command doesn't run is not pinned.
mkdir -p "$work/linux"
tar -xzf "$work/gita-linux-x64.tar.gz" -C "$work/linux"
reported=$("$work/linux/cli/bin/gita" --version)
[ "$reported" = "gita $latest" ] || fail "the Linux build reports \"$reported\", not \"gita $latest\""

# Each value is a version or a 64-character hex checksum, checked above, so
# it can't break the sed expressions.
sed -i \
  -e "s/^\( *local GITA_VERSION=\)\"[^\"]*\"/\1\"$latest\"/" \
  -e "s/^\( *local GITA_SHA256_MACOS=\)\"[^\"]*\"/\1\"${sha[gita-macos.zip]}\"/" \
  -e "s/^\( *local GITA_SHA256_LINUX=\)\"[^\"]*\"/\1\"${sha[gita-linux-x64.tar.gz]}\"/" \
  "$SH"
sed -i \
  -e "s/^\( *\$GitaVersion *= *\)'[^']*'/\1'$latest'/" \
  -e "s/^\( *\$GitaSha256 *= *\)'[^']*'/\1'${sha[gita-windows-x64.zip]}'/" \
  "$PS"

grep -q "GITA_VERSION=\"$latest\"" "$SH" || fail "install.sh wasn't updated"
grep -q "GITA_SHA256_LINUX=\"${sha[gita-linux-x64.tar.gz]}\"" "$SH" || fail "install.sh Linux checksum wasn't updated"
grep -q "GITA_SHA256_MACOS=\"${sha[gita-macos.zip]}\"" "$SH" || fail "install.sh macOS checksum wasn't updated"
grep -q "\$GitaVersion *= *'$latest'" "$PS" || fail "install.ps1 wasn't updated"
grep -q "\$GitaSha256 *= *'${sha[gita-windows-x64.zip]}'" "$PS" || fail "install.ps1 checksum wasn't updated"

echo "Pinned Gita $current -> $latest:"
for a in "${assets[@]}"; do echo "  $a ${sha[$a]}"; done
output "changed=true"
