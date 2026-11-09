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
#   TB_SKIP_STANDARDS=1 skip claude-standards and its setup (testing)
#   TB_GITA_ARCHIVE=<path>     install Gita from a local archive (testing, no checksum)
#   TB_ONBOARDING_FILE=<path>  use a local onboarding file (testing, no checksum)

# Everything is inside main, so a half-downloaded script runs nothing.
main() {
  set -euo pipefail

  # ---- Pinned versions. The gita-bump workflow updates these lines. ----
  local GITA_REPO="naseebnaushad/gita"
  local GITA_VERSION="1.1.0"
  # Checksums: filled in by the gita-bump workflow PR.
  local GITA_SHA256_MACOS="6d8815056bf654da30ef0b202367d705fc8b0d96bf82d22d7dcb435961d1093f"   # SHA-256 of gita-macos.zip
  local GITA_SHA256_LINUX="51e2142c3069985259d72da31b8dbc91a8a5bc80a9b53689074207ff3d24e616"   # SHA-256 of gita-linux-x64.tar.gz
  local ONBOARDING_URL="https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/thoughtbox-onboarding.json"
  local ONBOARDING_SHA256="a723840dd6b09911fea6b1afa42cfe641c21deb161d0cb66e3e9e6bf1431a196"

  local GITA_HOME="$HOME/.gita"
  local GITA_CLI="$GITA_HOME/bin/gita"
  local DRY="${TB_DRY_RUN:-0}"
  local ORIG_PATH="$PATH"
  export PATH="$GITA_HOME/bin:$HOME/.local/bin:$PATH"

  # Gita asks its questions on the terminal, not on the piped script.
  local TTY=/dev/tty
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
      [ "$(uname -m)" = x86_64 ] || fail "Gita is only built for x86_64 Linux (this is $(uname -m))."
      os=linux; asset="gita-linux-x64.tar.gz"; sha=$GITA_SHA256_LINUX
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
  # Gita only asks questions when both its input and output are a terminal, so
  # with a terminal it writes straight to it (the log can't hold that part).
  if [ "$TTY" != /dev/null ] && [ -t 3 ]; then
    note "(Gita's own output is shown in the terminal only, so it can ask you questions.)"
    "$gita" "${args[@]}" <"$TTY" >&3 2>&4 || rc=$?
  else
    "$gita" "${args[@]}" <"$TTY" || rc=$?
  fi
  return "$rc"
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
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 \
    --retry 3 --retry-delay 3 "$1" -o "$2"
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

main "$@"
