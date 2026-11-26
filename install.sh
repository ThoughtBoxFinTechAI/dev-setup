#!/usr/bin/env bash
# ThoughtBox developer setup for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.sh | bash
#
# Installs or updates Gita (a pinned release, checked against its SHA-256),
# downloads the ThoughtBox onboarding file (also checked), and runs
# "gita onboard" with it. Gita does the rest: Git, GitHub CLI and Claude Code,
# clean-up of old GitHub sign-ins, your two GitHub accounts (@thoughtbox.io and
# @thoughtbox.one), claude-standards and its setup, Gita in Claude Code, and a
# final check with a summary. Safe to run again: finished steps are skipped.
#
# Optional environment variables (set them before running, e.g. TB_DRY_RUN=1 bash):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_CLEAN=1          remove old GitHub sign-ins and settings without asking
#   TB_LOG=<path>       write the log here instead of ~/.thoughtbox-setup.log
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_TOKEN_SIGNIN=1 / TB_TOKEN_SIGNIN=0  offer to sign in with a classic token (hidden
#                       prompt) instead of the browser code, or never offer it
#                       (default: ask; no terminal = never offer). Tokens are never
#                       read from the environment or the command line.
#   TB_TOKEN_DAYS=30|90|180|365|none  how long a classic token should last, without
#                       showing the menu (default: menu, 1 year preselected)
#   TB_SKIP_STANDARDS=1 skip claude-standards and its setup (testing)
#   TB_GITA_ARCHIVE=<path>     install Gita from a local archive (testing, no checksum)
#   TB_ONBOARDING_FILE=<path>  use a local onboarding file (testing, no checksum)
#   TB_TTY=<path>      read answers from this file instead of the terminal (testing)
#   TB_FIGMA=1 / TB_FIGMA=0  set up the Figma MCP Bridge for frontend work (macOS),
#                       or skip it, without being asked (default: ask; no terminal = skip)

# Everything is inside main, so a half-downloaded script runs nothing.
main() {
  set -euo pipefail

  # ---- Pinned versions. The gita-bump workflow updates these lines. ----
  local GITA_REPO="naseebnaushad/gita"
  local GITA_VERSION="1.2.0"
  # Checksums: filled in by the gita-bump workflow PR.
  local GITA_SHA256_MACOS="fd309d002a4cb8098b025147b148c82a15bf394b459a2ebd10a65ce0b08aa78a"   # SHA-256 of gita-macos.zip
  local GITA_SHA256_LINUX="efebfac466515a00476117694ed2f9bc6aa0a0d4b5e345ce3315ae29a3ccc46c"   # SHA-256 of gita-linux-x64.tar.gz
  # Empty while the pinned Gita release has no arm64 Linux build.
  local GITA_SHA256_LINUX_ARM64=""   # SHA-256 of gita-linux-arm64.tar.gz
  local ONBOARDING_URL="https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/thoughtbox-onboarding.json"
  local ONBOARDING_SHA256="a723840dd6b09911fea6b1afa42cfe641c21deb161d0cb66e3e9e6bf1431a196"

  # ---- Pinned Figma MCP Bridge (optional step). Update together (see README). ----
  local FIGMA_VERSION="0.0.25"
  local FIGMA_NPM_SHA512="e4d49e8aed1cea7e18f42222ae4e854901341c9824e4f12c3a63b85d6abd61bfa16fc3ac39e7dda596bcb83440f26233ebc47fc6f458390967f6d85ed9aedb8a"   # SHA-512 of the npm tarball
  local FIGMA_PLUGIN_SHA256="bf50a9ce330193bceb916c0eeb7252ce72a696f92a3369528139b6a4376d8550"   # SHA-256 of the release zip
  local FIGMA_DIR="$HOME/.thoughtbox/figma-mcp-bridge"

  local GITA_HOME="$HOME/.gita"
  local GITA_CLI="$GITA_HOME/bin/gita"
  local DRY="${TB_DRY_RUN:-0}"
  local ORIG_PATH="$PATH"
  export PATH="$GITA_HOME/bin:$HOME/.local/bin:$PATH"

  # Gita asks its questions on the terminal, not on the piped script.
  local TTY=${TB_TTY:-/dev/tty}   # TB_TTY: a file to read answers from (testing)
  if ! { : <"$TTY"; } 2>/dev/null; then TTY=/dev/null; fi

  start_log
  trap on_exit EXIT
  # A run that was killed can't clean up; remove what earlier runs left.
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tb-gita.*' -user "$(id -u)" -mmin +60     -exec rm -rf {} + 2>/dev/null || true
  TB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/tb-gita.XXXXXX") || fail "Couldn't create a temporary folder."

  local os asset sha app_dir cli_dir
  case "$(uname -s)" in
    Darwin)
      # hw.optional.arm64, not uname -m, which says x86_64 under Rosetta.
      [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ||
        fail "Gita's gita command is only built for Apple silicon Macs (M1 or later); this Mac has an Intel processor."
      os=macos; asset="gita-macos.zip"; sha=$GITA_SHA256_MACOS
      app_dir="$HOME/Applications/gita.app"; cli_dir="$app_dir/Contents/Resources/cli" ;;
    Linux)
      os=linux
      case "$(uname -m)" in
        x86_64) asset="gita-linux-x64.tar.gz"; sha=$GITA_SHA256_LINUX ;;
        aarch64 | arm64)
          asset="gita-linux-arm64.tar.gz"; sha=$GITA_SHA256_LINUX_ARM64
          # A local archive (TB_GITA_ARCHIVE) needs no pinned checksum.
          [ -n "$sha" ] || [ -n "${TB_GITA_ARCHIVE:-}" ] ||
            fail "Gita $GITA_VERSION has no arm64 Linux build, so it can't be set up on this computer yet." \
              "Run this again after an admin updates the pinned Gita version to a release with gita-linux-arm64.tar.gz." ;;
        *) fail "Gita is only built for x86_64 and arm64 Linux (this is $(uname -m))." ;;
      esac
      app_dir="$HOME/.local/share/gita"; cli_dir="$app_dir/cli" ;;
    *) fail "Unsupported system $(uname -s). On Windows, use install.ps1." ;;
  esac

  # ---- 1. Gita ----
  say "Gita"
  local gita="$GITA_CLI" st
  st=$(gita_state)
  case $st in
    ok) [ -n "${TB_GITA_ARCHIVE:-}" ] || { note "Gita $GITA_VERSION is installed and runs."; st=keep; } ;;
    newer:*)
      [ -n "${TB_GITA_ARCHIVE:-}" ] ||
        { note "Gita ${st#newer:} is newer than this script's $GITA_VERSION; keeping it."; st=keep; } ;;
    older:*) note "Gita ${st#older:} is installed. Updating to $GITA_VERSION." ;;
    broken:*) warn "Gita is installed but doesn't run: $(broken_reason "${st#broken:}"). Reinstalling it." ;;
  esac
  if [ "$st" != keep ]; then
    fetch_gita
    if [ "$DRY" = 1 ]; then
      # A dry run installs nothing: it runs the downloaded copy from the temporary folder.
      note "[dry run] would install Gita $GITA_VERSION into $app_dir and $GITA_HOME"
      if [ "$os" = macos ]; then gita="$TB_TMP/app/gita.app/Contents/Resources/cli/bin/gita"
      else gita="$TB_TMP/app/cli/bin/gita"; fi
    else
      wait_for_gita_closed
      place_gita
      verify_gita
    fi
  fi
  fix_rc_path
  check_other_gita

  # ---- 2. The onboarding file ----
  local file="$TB_TMP/thoughtbox-onboarding.json"
  if [ -n "${TB_ONBOARDING_FILE:-}" ]; then
    warn "Using the local onboarding file $TB_ONBOARDING_FILE (no checksum check)."
    cp "$TB_ONBOARDING_FILE" "$file" || fail "Couldn't read $TB_ONBOARDING_FILE."
  else
    download "$ONBOARDING_URL" "$file" ||
      fail "Couldn't download the onboarding file." "Check your internet connection and that github.com opens in your browser, then run this again."
    [ "$(sha256_of "$file")" = "$ONBOARDING_SHA256" ] ||
      fail "The onboarding file doesn't match its pinned checksum." "Nothing was changed by it. Tell an admin."
  fi

  # ---- 3. gita onboard does the rest ----
  local args=(onboard "$file")
  [ -z "${TB_NAME:-}" ] || args+=(--name "$TB_NAME")
  [ -z "${TB_EMAIL_IO:-}" ] || args+=(--email "io=$TB_EMAIL_IO")
  [ -z "${TB_EMAIL_ONE:-}" ] || args+=(--email "one=$TB_EMAIL_ONE")
  [ "$DRY" != 1 ] || args+=(--dry-run)
  [ "${TB_CLEAN:-0}" != 1 ] || args+=(--clean)
  [ "${TB_SKIP_SIGNIN:-0}" != 1 ] || args+=(--skip-sign-in)
  [ "${TB_SKIP_STANDARDS:-0}" != 1 ] || args+=(--skip-repos)
  echo >&2
  local rc=0
  TB_GITA_RAN=1
  # Optional: classic tokens instead of the browser code. Gita first creates the
  # profiles (no sign-in, no repositories); the tokens are then saved with
  # "gita sign-in --with-token"; the full run below keeps a sign-in that works
  # and only asks for the browser code for accounts that have none.
  if want_token_signin; then
    token_signin "$gita" "$file" "${args[@]:2}" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
  fi
  run_gita "$gita" "${args[@]}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"

  # ---- 4. Optional: Figma for frontend work ----
  if want_figma; then
    if [ "$os" != macos ]; then
      note "Figma for frontend work is skipped: the Figma desktop app (which the bridge needs) isn't available on Linux."
    else
      echo >&2
      say "Setting up Figma for frontend work"
      # A subshell, so a "Setup stopped" inside only ends this optional step.
      if (install_figma_bridge); then
        [ "$DRY" = 1 ] || {
          record "Figma, once: open the Figma desktop app, then Plugins > Development >"
          record "  Import plugin from manifest... and pick:"
          record "    $FIGMA_DIR/plugin/manifest.json"
          record "  Then open the shared Figma file, run \"Figma MCP Bridge\" from"
          record "  Plugins > Development, and start (or restart) claude."
        }
      else
        warn "The Figma step didn't finish (see the message above). Everything else is set up."
        warn "Fix that and run the setup again with TB_FIGMA=1."
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- output

say()  { printf '\033[36m==> %s\033[0m\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
has()  { command -v "$1" >/dev/null 2>&1; }

# fail "what went wrong" ["what to do" ...]: stops the setup.
fail() {
  printf '\033[31mSetup stopped: %s\033[0m\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  note "Fix the problem above and run the same command again."
  exit 1
}

TB_LOG_FILE=""
TB_TMP=""
TB_GITA_RAN=0
TB_NOTES=()
record() { TB_NOTES+=("$1"); }   # a line for the script's short summary

on_exit() {
  local rc=$? n
  [ -z "$TB_TMP" ] || rm -rf "$TB_TMP"
  [ "$TB_GITA_RAN" = 0 ] || [ "$rc" = 0 ] || note "Gita stopped with exit code $rc (see above)."
  if [ ${#TB_NOTES[@]} -gt 0 ]; then
    say "From the setup script"
    for n in "${TB_NOTES[@]}"; do note "$n"; done
  fi
  [ -z "$TB_LOG_FILE" ] || note "Log of this run: $TB_LOG_FILE (send it when asking for help)."
}

# The log holds this run only, readable by you only. No step prints a token.
# fd 3 and 4 keep the real output, for Gita when it needs the terminal.
start_log() {
  exec 3>&1 4>&2
  TB_LOG_FILE="${TB_LOG:-$HOME/.thoughtbox-setup.log}"
  rm -f "$TB_LOG_FILE" 2>/dev/null || true
  if ! ( umask 077 && : >"$TB_LOG_FILE" ) 2>/dev/null; then
    warn "Couldn't create the log file $TB_LOG_FILE; carrying on without it."
    TB_LOG_FILE=""; return 0
  fi
  chmod 600 "$TB_LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$TB_LOG_FILE") 2>&1
  note "ThoughtBox dev-setup, $(date '+%Y-%m-%d %H:%M:%S'), $(uname -sm)"
}

download() {  # url file
  # GitHub's release downloads sometimes fail for a moment (a CI run hit
  # a 504): retry every error, five times, with a longer wait.
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 \
    --retry 5 --retry-delay 10 --retry-all-errors "$1" -o "$2"
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ---------------------------------------------------------------- Gita

# version_cmp a b: prints newer | older | same (a compared with b). Dotted
# numbers, compared as numbers; anything after "-" is ignored.
version_cmp() {
  local a=${1%%-*} b=${2%%-*} x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x=${a%%.*}; y=${b%%.*}
    x=${x//[^0-9]/}; y=${y//[^0-9]/}
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    if [ "$x" -gt "$y" ]; then echo newer; return; fi
    if [ "$x" -lt "$y" ]; then echo older; return; fi
    case $a in *.*) a=${a#*.} ;; *) a="" ;; esac
    case $b in *.*) b=${b#*.} ;; *) b="" ;; esac
  done
  echo same
}

# Prints missing | ok | older:<version> | newer:<version> | broken:<reason code>.
gita_state() {
  [ -e "$GITA_CLI" ] || { echo missing; return; }
  # The Mac app copies its own command over ~/.gita when it starts, so the
  # copy inside gita.app has to run too (see fix_macos_cli_signature).
  if [ "$os" = macos ] && ! { "$cli_dir/bin/gita" --version; } >/dev/null 2>&1; then
    echo broken:app; return
  fi
  local out rc=0
  # Braces: bash itself prints "Killed: 9" for a killed command otherwise.
  out=$({ "$GITA_CLI" --version; } 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then echo "broken:$rc"; return; fi
  case $out in "gita "[0-9]*) ;; *) echo broken:version; return ;; esac
  out=${out#gita }
  case $(version_cmp "$out" "$GITA_VERSION") in
    same) echo ok ;;
    newer) echo "newer:$out" ;;
    *) echo "older:$out" ;;
  esac
}

broken_reason() {  # reason code
  case $1 in
    app) echo "the gita command inside the Gita app doesn't start" ;;
    version) echo "it doesn't say its version" ;;
    137) echo "the system stopped it (Killed: 9)" ;;
    126) echo "it isn't allowed to run" ;;
    127) echo "a file it needs is missing" ;;
    *) echo "it exits with code $1" ;;
  esac
}

# Gets the Gita release (or the local archive) into $TB_TMP/app and checks it.
fetch_gita() {
  local file="$TB_TMP/$asset" url
  if [ -n "${TB_GITA_ARCHIVE:-}" ]; then
    warn "Using the local file $TB_GITA_ARCHIVE (no checksum check)."
    cp "$TB_GITA_ARCHIVE" "$file" || fail "Couldn't read $TB_GITA_ARCHIVE."
  else
    [ -n "$sha" ] || fail "Gita $GITA_VERSION has no pinned checksum in this script yet." "Ask an admin."
    url="https://github.com/$GITA_REPO/releases/download/v$GITA_VERSION/$asset"
    note "Downloading $url"
    download "$url" "$file" ||
      fail "Couldn't download Gita." "Check your internet connection and that github.com opens in your browser, then run this again."
    [ "$(sha256_of "$file")" = "$sha" ] ||
      fail "The Gita download doesn't match its pinned checksum." "Nothing was installed. Tell an admin."
    note "Checksum OK."
  fi
  mkdir -p "$TB_TMP/app"
  if [ "$os" = macos ]; then
    ditto -x -k "$file" "$TB_TMP/app" || fail "Couldn't unpack the Gita download." "Run this again; if it repeats, tell an admin."
    [ -x "$TB_TMP/app/gita.app/Contents/Resources/cli/bin/gita" ] || fail "The Gita download has no gita.app." "Tell an admin."
    fix_macos_cli_signature "$TB_TMP/app/gita.app"
  else
    tar -xzf "$file" -C "$TB_TMP/app" || fail "Couldn't unpack the Gita download." "Run this again; if it repeats, tell an admin."
    [ -x "$TB_TMP/app/cli/bin/gita" ] || fail "The Gita download has no cli/bin/gita." "Tell an admin."
  fi
}

# Replacing the app while it runs would break it; ask to quit it first.
wait_for_gita_closed() {
  has pgrep || return 0
  pgrep -f "$app_dir/" >/dev/null 2>&1 || return 0
  [ "$TTY" != /dev/null ] || fail "The Gita app is open." "Quit Gita, then run this again."
  warn "The Gita app is open. Quit it (Gita menu > Quit), then press Enter."
  local _
  IFS= read -r _ <"$TTY" || true
  if pgrep -f "$app_dir/" >/dev/null 2>&1; then
    fail "The Gita app is still open." "Quit Gita, then run this again."
  fi
}

place_gita() {
  say "Installing Gita $GITA_VERSION"
  mkdir -p "$(dirname "$app_dir")"
  rm -rf "$app_dir"
  if [ "$os" = macos ]; then
    mv "$TB_TMP/app/gita.app" "$app_dir"
  else
    mv "$TB_TMP/app" "$app_dir"
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/gita.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Gita
Comment=Keep each project on the right GitHub account
Exec=$app_dir/gita
Terminal=false
Categories=Development;
EOF
  fi
  # Same layout the Gita app keeps: ~/.gita/bin and ~/.gita/lib. Git runs the
  # credential helper from here, so this path must not change.
  # Delete first, then copy: copying over a signed program on macOS keeps the
  # old cached signature and the system kills the new one ("Killed: 9").
  # Only bin and lib are replaced; profiles and settings in ~/.gita stay.
  local d
  for d in bin lib; do
    rm -rf "${GITA_HOME:?}/$d"
    [ -d "$cli_dir/$d" ] || continue
    mkdir -p "$GITA_HOME/$d"
    cp -R "$cli_dir/$d/." "$GITA_HOME/$d/"
  done
  [ -f "$GITA_CLI" ] || fail "The Gita download has no command-line program." "Tell an admin."
  chmod +x "$GITA_CLI"
}

verify_gita() {
  local st; st=$(gita_state)
  case $st in
    ok) note "Gita $GITA_VERSION is installed and runs." ;;
    older:* | newer:*)
      # A local test build may carry another version number.
      [ -n "${TB_GITA_ARCHIVE:-}" ] ||
        fail "Gita was installed but reports version ${st#*:} instead of $GITA_VERSION." "Tell an admin."
      warn "The local file holds Gita ${st#*:}, not $GITA_VERSION." ;;
    broken:*) fail "Gita was installed but doesn't run: $(broken_reason "${st#broken:}")." \
      "Run \"$GITA_CLI --version\" to see the error, and send it with the log to an admin." ;;
    *) fail "Gita was installed but $GITA_CLI is missing." "Tell an admin." ;;
  esac
}

# Gita 1.0.2's command is signed with the hardened runtime but without the
# entitlement the Dart runtime needs to run its compiled code, so newer macOS
# kills it on start ("Killed: 9"). If the bundled command won't run, sign it
# again (ad hoc) with that entitlement. It is fixed inside gita.app, not just
# in ~/.gita, because the app copies its command to ~/.gita every time it
# starts. Does nothing once a Gita release ships a command that runs.
fix_macos_cli_signature() {  # gita.app folder
  local app=$1 dir="$1/Contents/Resources/cli" ent="$TB_TMP/cli.entitlements" f
  { "$dir/bin/gita" --version; } >/dev/null 2>&1 && return 0   # braces: no "Killed: 9" line
  note "Re-signing the gita command so macOS lets it run."
  cat >"$ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
</dict>
</plist>
EOF
  find "$dir" -type f \( -perm -u+x -o -name '*.dylib' \) | while IFS= read -r f; do
    codesign --force --sign - --options runtime --entitlements "$ent" "$f" 2>/dev/null ||
      fail "Couldn't re-sign $f."
  done
  # Re-seal the app, since files inside it changed, keeping its own entitlements.
  codesign --force --sign - --preserve-metadata=entitlements,flags "$app" 2>/dev/null ||
    fail "Couldn't re-sign $app."
  { "$dir/bin/gita" --version; } >/dev/null 2>&1 ||
    fail "The gita command still won't run on this Mac after re-signing it." "Tell an admin."
}

TB_MARK="# Added by ThoughtBox dev-setup"

# rc_tidied line < rc: the rc file without the PATH blocks this script (or an
# older version of it) wrote, then one block per PATH line at the end:
# ~/.local/bin (only if an older version added it) and ~/.gita/bin last, so
# that ~/.gita/bin is the last PATH change and comes first in PATH. A block is
# the marker line plus the "export PATH=" line for .gita/bin or .local/bin
# right after it, and the empty line written before it. Other lines stay.
rc_tidied() {
  awk -v marker="$TB_MARK" -v gline="$1" '
    function out(l) { while (blanks > 0) { print ""; blanks-- } print l }
    function plain(l) {
      if (l == marker) { held = 1; return }
      if (l == "") { blanks++; return }
      out(l)
    }
    {
      if (held) {
        held = 0
        if ($0 ~ /^export PATH=/ && $0 ~ /\.(gita|local)\/bin/) {
          if (blanks > 0) blanks--
          if ($0 !~ /\.gita\/bin/ && !seen[$0]++) keep[++n] = $0
          next
        }
        out(marker)
      }
      plain($0)
    }
    END {
      if (held) out(marker)
      while (blanks > 0) { print ""; blanks-- }
      for (i = 1; i <= n; i++) printf "\n%s\n%s\n", marker, keep[i]
      printf "\n%s\n%s\n", marker, gline
    }'
}

# A free "<path>.backup-<date-time>" name; never overwrites an earlier backup.
backup_name() {
  local b n=2
  b="$1.backup-$(date +%Y%m%d-%H%M%S)"
  while [ -e "$b" ] || [ -L "$b" ]; do b="$1.backup-$(date +%Y%m%d-%H%M%S)-$n"; n=$((n + 1)); done
  printf '%s' "$b"
}

# Puts ~/.gita/bin on PATH in ~/.zshrc and ~/.bashrc with exactly one block, at
# the end. The default shell's file is created if needed; the other is used if
# present. A changed file is backed up first (owner-only).
fix_rc_path() {
  local rc short new="$TB_TMP/rc.new" backup line main_rc="$HOME/.bashrc"
  # shellcheck disable=SC2016
  line='export PATH="$HOME/.gita/bin:$PATH"'
  [ "$os" = macos ] && main_rc="$HOME/.zshrc"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || [ "$rc" = "$main_rc" ] || continue
    short="~${rc#"$HOME"}"
    { [ ! -f "$rc" ] || cat "$rc"; } | rc_tidied "$line" >"$new"
    [ -f "$rc" ] && cmp -s "$new" "$rc" && continue
    if [ ! -f "$rc" ]; then
      if [ "$DRY" = 1 ]; then note "[dry run] would create $short with ~/.gita/bin on PATH"; continue; fi
      ( umask 077 && cat "$new" >"$rc" ) || { warn "Couldn't create $rc."; continue; }
      record "Added ~/.gita/bin to PATH in $short (new file)"; continue
    fi
    if [ "$DRY" = 1 ]; then
      note "[dry run] would back up $short and put one ~/.gita/bin PATH line at its end"
      record "Would tidy PATH lines in $short (dry run)"; continue
    fi
    backup=$(backup_name "$rc")
    if ! ( umask 077 && cp "$rc" "$backup" && chmod 600 "$backup" ); then
      warn "Couldn't back up $rc, so it was not changed. Add $line at its end yourself."; continue
    fi
    cat "$new" >"$rc" || { warn "Couldn't change $rc (backup: $backup)."; continue; }
    if grep -qxF "$TB_MARK" "$backup"; then
      record "Tidied PATH lines in $short (backup: $backup)"
    else
      record "Added ~/.gita/bin to PATH in $short (backup: $backup)"
    fi
  done
}

# Another gita earlier on PATH (e.g. Homebrew's) would run instead of Gita's.
# New terminals put ~/.gita/bin first (see fix_rc_path); this only reports.
check_other_gita() {
  local dirs dir mine real p seen=" "
  mine=$(cd "$GITA_HOME/bin" 2>/dev/null && pwd -P) || mine="$GITA_HOME/bin"
  IFS=: read -ra dirs <<<"$ORIG_PATH"
  for dir in "${dirs[@]}"; do
    p="$dir/gita"
    { [ -n "$dir" ] && [ -f "$p" ] && [ -x "$p" ]; } || continue
    real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    [ "$real" != "$mine" ] || continue
    case $seen in *" $real "*) continue ;; esac
    seen="$seen$real "
    warn "Another gita is at $p. New terminals use ~/.gita/bin first, so it is now behind Gita's; open a new terminal."
    case $p in
      /opt/homebrew/* | /usr/local/* | /home/linuxbrew/*)
        note 'If it came from Homebrew, you can remove it with "brew uninstall gita".' ;;
      *) note "You can remove it if you don't need it." ;;
    esac
    if [ "$DRY" = 1 ]; then record "Another gita at $p would be behind ~/.gita/bin (dry run)"
    else record "Another gita at $p is now behind ~/.gita/bin"; fi
  done
}

# ---------------------------------------------------------------- classic token sign-in (optional)

# run_gita <gita> <args...>: Gita only asks questions when both its input and
# output are a terminal, so with a terminal it writes straight to it (the log
# can't hold that part).
run_gita() {
  local g=$1; shift
  if [ "$TTY" != /dev/null ] && [ -t 3 ]; then
    note "(Gita's own output is shown in the terminal only, so it can ask you questions.)"
    "$g" "$@" <"$TTY" >&3 2>&4
  else
    "$g" "$@" <"$TTY"
  fi
}

# TB_TOKEN_SIGNIN answers up front; otherwise ask. No terminal, a dry run or
# TB_SKIP_SIGNIN=1 means no.
want_token_signin() {
  local answer
  [ "$DRY" != 1 ] || { [ "${TB_TOKEN_SIGNIN:-}" != 1 ] || note "[dry run] would sign in with classic tokens"; return 1; }
  [ "${TB_SKIP_SIGNIN:-0}" != 1 ] || return 1
  case "${TB_TOKEN_SIGNIN:-}" in
    1) return 0 ;;
    0) return 1 ;;
    "") ;;
    *) warn "TB_TOKEN_SIGNIN must be 1 or 0 (it is \"$TB_TOKEN_SIGNIN\"), so the token option is not offered."; return 1 ;;
  esac
  [ "$TTY" != /dev/null ] || return 1
  printf 'Sign in to GitHub with a classic token instead of the browser code? [y/N]: ' >&2
  IFS= read -r answer <"$TTY" || true
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ "$answer" = y ] || [ "$answer" = yes ]
}

# The scopes Gita needs, as GitHub's "new classic token" page takes them.
TB_TOKEN_URL="https://github.com/settings/tokens/new?description=Gita&scopes=repo,workflow,read:user,user:email,write:public_key,read:org"

# json_values <key> < file: the string values of a key, one per line. The
# onboarding file is pinned by checksum and has one key per line.
json_values() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/^[^:]*:[[:space:]]*"\(.*\)"$/\1/'
}

# menu <title> <default index> <label>...: a small arrow-key menu on the terminal
# (up/down or k/j, a digit to jump, Enter to accept). Sets MENU_CHOICE to the
# chosen index (1-based). Without a real terminal (TB_TTY, tests) it reads a
# line: a digit, or Enter for the default.
menu() {
  local title=$1 sel=$2 i k rest n; shift 2
  local items=("$@"); n=${#items[@]}
  printf '%s\n' "$title" >&2
  if [ ! -c "$TTY" ]; then
    for i in $(seq 1 "$n"); do printf '  %s) %s\n' "$i" "${items[$((i - 1))]}" >&2; done
    printf 'Choose 1-%s [%s]: ' "$n" "$sel" >&2
    IFS= read -r k <"$TTY" || true
    k=$(printf '%s' "$k" | tr -d '[:space:]')
    case $k in [1-9]) [ "$k" -le "$n" ] && sel=$k ;; esac
    MENU_CHOICE=$sel; return 0
  fi
  _menu_draw() {
    local j
    for j in $(seq 1 "$n"); do
      if [ "$j" = "$sel" ]; then printf '\033[2K  \033[36m> %s\033[0m\n' "${items[$((j - 1))]}" >&2
      else printf '\033[2K    %s\n' "${items[$((j - 1))]}" >&2; fi
    done
  }
  # Keys that arrive between two reads must not be echoed onto the menu.
  local saved
  saved=$(stty -g <"$TTY" 2>/dev/null) || saved=""
  [ -z "$saved" ] || stty -echo <"$TTY" 2>/dev/null || true
  printf '  (arrow keys to move, Enter to choose)\n' >&2
  _menu_draw
  while :; do
    IFS= read -rsn1 k <"$TTY" || break
    case $k in
      "") break ;;
      $'\033') IFS= read -rsn2 -t 1 rest <"$TTY" || true
        case $rest in '[A') [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;; '[B') [ "$sel" -lt "$n" ] && sel=$((sel + 1)) ;; esac ;;
      k) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
      j) [ "$sel" -lt "$n" ] && sel=$((sel + 1)) ;;
      [1-9]) [ "$k" -le "$n" ] && sel=$k ;;
    esac
    printf '\033[%sA' "$n" >&2
    _menu_draw
  done
  [ -z "$saved" ] || stty "$saved" <"$TTY" 2>/dev/null || true
  MENU_CHOICE=$sel
}

# date_in_days <n>: the date n days from now, as YYYY-MM-DD (macOS or GNU date).
date_in_days() { date -v+"$1"d +%Y-%m-%d 2>/dev/null || date -d "+$1 days" +%Y-%m-%d; }

# days_between <YYYY-MM-DD> <YYYY-MM-DD>: whole days from the first to the second.
days_between() {
  local a b
  a=$(date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || date -d "$1" +%s) || return 1
  b=$(date -j -f %Y-%m-%d "$2" +%s 2>/dev/null || date -d "$2" +%s) || return 1
  echo $(((b - a) / 86400))
}

# choose_token_days: sets TOKEN_DAYS (a number, or "none"). TB_TOKEN_DAYS skips the menu.
choose_token_days() {
  case "${TB_TOKEN_DAYS:-}" in
    30 | 90 | 180 | 365 | none) TOKEN_DAYS=$TB_TOKEN_DAYS; return 0 ;;
    "") ;;
    *) warn "TB_TOKEN_DAYS must be 30, 90, 180, 365 or none (it is \"$TB_TOKEN_DAYS\"); showing the menu." ;;
  esac
  menu "How long should the token last?" 4 \
    "30 days" "90 days" "180 days" "1 year (recommended)" "No expiry (not recommended)"
  case $MENU_CHOICE in 1) TOKEN_DAYS=30 ;; 2) TOKEN_DAYS=90 ;; 3) TOKEN_DAYS=180 ;; 5) TOKEN_DAYS=none ;; *) TOKEN_DAYS=365 ;; esac
}

# token_expiry <token>: prints the token's expiry as GitHub reports it
# ("2027-11-23 00:00:00 UTC"), or "none". The token goes to curl on its stdin
# (a config), never on the command line, where other users' ps could see it.
token_expiry() {
  has curl || return 1
  local head
  head=$(printf 'header = "Authorization: Bearer %s"\n' "$1" |
    curl -sSI --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 -K - https://api.github.com/user 2>/dev/null |
    tr -d '\r') || return 1
  case $head in HTTP/*" 200"*) ;; *) return 1 ;; esac
  printf '%s\n' "$head" | awk 'tolower($1) == "github-authentication-token-expiration:" { $1 = ""; print substr($0, 2); found = 1 } END { if (!found) print "none" }'
}

# report_token_expiry <token> <wanted YYYY-MM-DD or empty for none>: says when the
# token expires and warns if that is not what was chosen.
report_token_expiry() {
  local actual day gap
  actual=$(token_expiry "$1") || { note "Couldn't ask GitHub when this token expires."; return 0; }
  if [ "$actual" = none ]; then
    if [ -n "$2" ]; then warn "This token never expires, but you chose $2. Fine, or create a new one with an expiry."
    else note "This token does not expire."; fi
    return 0
  fi
  day=${actual%% *}
  if [ -z "$2" ]; then warn "This token expires on $day, but you chose no expiry."; return 0; fi
  gap=$(days_between "$day" "$2") || gap=0
  if [ "$gap" -gt 3 ]; then
    warn "This token expires on $day, sooner than the $2 you chose. Run the setup again before then, or create a longer one."
  else
    note "This token expires on $day. Run the setup again before then to renew it."
  fi
}

# token_signin <gita> <onboarding file> [onboard options...]: creates the
# profiles, then offers a hidden prompt for a classic token per account.
token_signin() {
  local g=$1 file=$2; shift 2
  local labels domains n i label domain tok answer tries out rc=0
  labels=$(json_values label <"$file")
  domains=$(json_values emailDomain <"$file")
  n=$(printf '%s\n' "$labels" | grep -c .)
  if [ "$n" -eq 0 ] || [ "$n" -ne "$(printf '%s\n' "$domains" | grep -c .)" ]; then
    warn "Couldn't read the accounts from the onboarding file, so tokens are not offered. Using the browser code."
    return 0
  fi
  say "Preparing your Gita profiles"
  run_gita "$g" onboard "$file" --skip-sign-in --skip-repos "$@" || rc=$?
  [ "$rc" = 0 ] || return "$rc"

  for i in $(seq 1 "$n"); do
    label=$(printf '%s\n' "$labels" | sed -n "${i}p")
    domain=$(printf '%s\n' "$domains" | sed -n "${i}p")
    printf '\nUse a classic token for "%s" (your @%s account)? [y/N]: ' "$label" "$domain" >&2
    IFS= read -r answer <"$TTY" || true
    answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [ "$answer" = y ] || [ "$answer" = yes ] || { note "Using the browser code for \"$label\"."; continue; }
    choose_token_days
    local want_date=""
    note "Create a classic token while signed in to GitHub as that account (the scopes are ticked for you):"
    note "  $TB_TOKEN_URL"
    if [ "$TOKEN_DAYS" = none ]; then
      note "Under Expiration, choose \"No expiration\"."
    else
      want_date=$(date_in_days "$TOKEN_DAYS")
      note "Under Expiration, pick \"Custom\" and set $want_date ($TOKEN_DAYS days), or the closest choice."
    fi
    note "The token is saved in your system's key store, not on disk."
    tries=0
    while [ "$tries" -lt 3 ]; do
      tries=$((tries + 1))
      # Echo off before the prompt is shown, so even a fast paste is never displayed.
      local saved_tty
      saved_tty=$(stty -g <"$TTY" 2>/dev/null) || saved_tty=""
      [ -z "$saved_tty" ] || stty -echo <"$TTY" 2>/dev/null || true
      printf 'Paste the token (nothing shows while you type), or press Enter for the browser code: ' >&2
      IFS= read -rs tok <"$TTY" || true
      [ -z "$saved_tty" ] || stty "$saved_tty" <"$TTY" 2>/dev/null || true
      printf '\n' >&2
      tok=$(printf '%s' "$tok" | tr -d '[:space:]')
      if [ -z "$tok" ]; then note "Using the browser code for \"$label\"."; break; fi
      case $tok in
        ghp_*) ;;
        github_pat_*) warn "That is a fine-grained token. A classic token (ghp_...) is expected; fine-grained ones can miss scopes Gita needs." ;;
        *) warn "That doesn't look like a GitHub token (a classic one starts with ghp_)."; tok=""; continue ;;
      esac
      # The token goes in through stdin: never on a command line or in the log.
      out=$(printf '%s' "$tok" | "$g" sign-in --profile "$label" --with-token --force 2>&1) && rc=0 || rc=$?
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      if [ "$rc" = 0 ]; then report_token_expiry "$tok" "$want_date"; tok=""; break; fi
      tok=""
      warn "GitHub didn't accept that token (see above)."
      [ "$tries" -lt 3 ] || note "Giving up on a token for \"$label\"; the browser code is used instead."
    done
    tok=""
  done
  rc=0
  return 0
}

# ---------------------------------------------------------------- Figma (optional, see the README)

# TB_FIGMA answers up front; otherwise ask. No terminal to ask in means no.
want_figma() {
  local answer
  case "${TB_FIGMA:-}" in
    1) return 0 ;;
    0) return 1 ;;
    "") ;;
    *) warn "TB_FIGMA must be 1 or 0 (it is \"$TB_FIGMA\"), so the Figma step is skipped."; return 1 ;;
  esac
  [ "$TTY" != /dev/null ] || return 1
  printf 'Set up Figma for frontend work (Figma MCP Bridge)? [y/N]: ' >&2
  IFS= read -r answer <"$TTY" || true
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ "$answer" = y ] || [ "$answer" = yes ]
}

node_major() {
  local v
  has node || { echo 0; return; }
  v=$(node --version 2>/dev/null || true)
  v=${v#v}; v=${v%%.*}
  case "$v" in '' | *[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

sha512_of() {
  if has sha512sum; then sha512sum "$1" | cut -d' ' -f1; else shasum -a 512 "$1" | cut -d' ' -f1; fi
}

# macOS only. Runs in a subshell: set -e doesn't apply there (it is the left side
# of an "if"), so every step checks its own result and calls fail.
install_figma_bridge() {
  # Node.js runs the bridge server (it needs 20 or later).
  if [ "$(node_major)" -ge 20 ]; then
    note "Node.js $(node --version) is installed."
  else
    has brew || fail 'Node.js 20 or later is needed.' 'Install Homebrew (https://brew.sh) or Node.js LTS (https://nodejs.org), then run this again.'
    say "Installing Node.js"
    if [ "$DRY" = 1 ]; then
      note "[dry run] would install Node.js with Homebrew"
    else
      brew install node <"$TTY" || fail "Installing Node.js with Homebrew failed."
      [ "$(node_major)" -ge 20 ] ||
        fail 'Node.js 20 or later is needed, but "node --version" still shows an older one (or none).' 'Switch with your version manager, or remove the old Node.js, and run this again.'
    fi
  fi

  # The plugin runs only in the Figma desktop app, not in the browser.
  if [ -d /Applications/Figma.app ] || [ -d "$HOME/Applications/Figma.app" ]; then
    note "The Figma desktop app is installed."
  elif has brew; then
    say "Installing the Figma desktop app"
    if [ "$DRY" = 1 ]; then
      note "[dry run] would install the Figma desktop app with Homebrew"
    elif ! brew install --cask figma <"$TTY"; then
      warn "The Figma desktop app was not installed. Get it from https://www.figma.com/downloads/."
    fi
  else
    warn "The Figma desktop app isn't installed. Get it from https://www.figma.com/downloads/."
  fi

  # Bridge server and plugin, both checked against the pinned checksums.
  local entry="$FIGMA_DIR/server/node_modules/@gethopp/figma-mcp-bridge/dist/index.js"
  local manifest="$FIGMA_DIR/plugin/manifest.json"
  local current=""
  [ -f "$FIGMA_DIR/version" ] && current=$(tr -d '[:space:]' <"$FIGMA_DIR/version")
  if [ "$current" = "$FIGMA_VERSION" ] && [ -f "$entry" ] && [ -f "$manifest" ]; then
    note "Figma MCP Bridge $FIGMA_VERSION is installed."
  else
    say "Installing Figma MCP Bridge $FIGMA_VERSION"
    if [ "$DRY" = 1 ]; then
      note "[dry run] would download and install Figma MCP Bridge into $FIGMA_DIR"
    else
      install_figma_files
    fi
  fi

  # Claude Code entry. run_script is on by team decision (CR-0.1.0-02, D5).
  if ! has claude; then
    warn "Claude Code is not on PATH yet, so the bridge was not added to it. Run this setup again in a new terminal."
    return 0
  fi
  if [ "$DRY" = 1 ]; then note "[dry run] would add figma-bridge to Claude Code"; return 0; fi
  local node_bin existing
  node_bin=$(command -v node)
  existing=$(claude mcp get figma-bridge 2>/dev/null </dev/null || true)
  case "$existing" in
    *"$entry"*)
      case "$existing" in
        *"$node_bin"*FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1* | *FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1*"$node_bin"*)
          note "figma-bridge is already in Claude Code."; return 0 ;;
      esac ;;
  esac
  claude mcp remove figma-bridge --scope user >/dev/null 2>&1 </dev/null || true
  claude mcp add figma-bridge --scope user --env FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1 -- "$node_bin" "$entry" >/dev/null </dev/null ||
    fail "Adding figma-bridge to Claude Code failed."
  note "Added figma-bridge to Claude Code."
}

install_figma_files() {
  local work tgz zip url actual stage
  if pgrep -f "$FIGMA_DIR/server" >/dev/null 2>&1; then
    fail "The Figma bridge is running." "Close Claude Code (and any other AI tool using it), then run this again."
  fi
  work="$TB_TMP/figma"
  mkdir -p "$work" || fail "Couldn't make a temporary folder."

  note "Downloading @gethopp/figma-mcp-bridge@$FIGMA_VERSION from npm"
  (cd "$work" && npm pack "@gethopp/figma-mcp-bridge@$FIGMA_VERSION" --silent >/dev/null </dev/null) ||
    fail "Couldn't download the bridge server from npm."
  tgz=$(find "$work" -maxdepth 1 -name '*.tgz' | head -n 1)
  [ -n "$tgz" ] || fail "npm didn't produce the bridge server package."
  actual=$(sha512_of "$tgz")
  [ "$actual" = "$FIGMA_NPM_SHA512" ] ||
    fail "The bridge server download doesn't match its pinned checksum." "Nothing was installed. Tell an admin."

  zip="$work/plugin.zip"
  url="https://github.com/gethopp/figma-mcp-bridge/releases/download/v$FIGMA_VERSION/figma-mcp-bridge-v$FIGMA_VERSION.zip"
  note "Downloading $url"
  download "$url" "$zip" || fail "Couldn't download the Figma plugin."
  actual=$(sha256_of "$zip")
  [ "$actual" = "$FIGMA_PLUGIN_SHA256" ] ||
    fail "The Figma plugin download doesn't match its pinned checksum." "Nothing was installed. Tell an admin."
  note "Checksums OK."

  # Build the new copy next to the downloads, then swap it in.
  stage="$work/bridge"
  mkdir -p "$stage/server" "$work/zip" || fail "Couldn't make a temporary folder."
  npm install --prefix "$stage/server" "$tgz" --ignore-scripts --omit=dev --no-audit --no-fund --silent </dev/null ||
    fail "Couldn't install the bridge server's packages with npm."
  ditto -x -k "$zip" "$work/zip" || fail "Couldn't unpack the Figma plugin."
  [ -f "$work/zip/plugin/manifest.json" ] || fail "The Figma plugin download has no plugin/manifest.json."
  mv "$work/zip/plugin" "$stage/plugin" || fail "Couldn't unpack the Figma plugin."
  printf '%s\n' "$FIGMA_VERSION" >"$stage/version" || fail "Couldn't write $stage/version."

  rm -rf "$FIGMA_DIR" || fail "Couldn't remove the old $FIGMA_DIR."
  mkdir -p "$(dirname "$FIGMA_DIR")" || fail "Couldn't make $(dirname "$FIGMA_DIR")."
  mv "$stage" "$FIGMA_DIR" || fail "Couldn't move the bridge into $FIGMA_DIR."
  note "Installed Figma MCP Bridge $FIGMA_VERSION."
}

main "$@"
