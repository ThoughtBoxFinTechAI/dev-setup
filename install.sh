#!/usr/bin/env bash
# ThoughtBox developer setup for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.sh | bash
#
# Installs Git, GitHub CLI, Claude Code and Gita, cleans up old GitHub sign-ins,
# sets up your two GitHub accounts (@thoughtbox.io and @thoughtbox.one), clones
# claude-standards and runs its setup. Safe to run again: every step checks what
# is already there first, and repairs or reinstalls what is broken.
#
# Optional environment variables (set them before running, e.g. TB_DRY_RUN=1 bash):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_CLEAN=1          remove old GitHub sign-ins and settings without asking
#   TB_LOG=<path>       write the log here instead of ~/.thoughtbox-setup.log
#   TB_GITA_ARCHIVE=<path>  install Gita from a local archive (testing, no checksum)
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_SKIP_STANDARDS=1 skip claude-standards and the Claude Code setup (testing)

# Everything is inside main, so a half-downloaded script runs nothing.
main() {
  set -euo pipefail

  # ---- Pinned versions. Update with every Gita release (see README). ----
  local GITA_REPO="naseebnaushad/gita"
  local GITA_VERSION="1.0.3"
  local GITA_SHA256_MACOS="8613eedd7bddd50058df52d2c1baf7c247e71b52fd80689fcd817f969d7335b9"   # SHA-256 of gita-macos.zip
  local GITA_SHA256_LINUX="d6ec88152bbe7d6c31c4f62c20bd713f21279d8a3cfb464759fe36405984ec71"   # SHA-256 of gita-linux-x64.tar.gz

  local STANDARDS_URL="https://github.com/ThoughtBoxFinTechAI/claude-standards.git"
  local STANDARDS_DIR="$HOME/claude-standards"
  local GITA_HOME="$HOME/.gita"
  local GITA_CLI="$GITA_HOME/bin/gita"
  local LABEL_IO="ThoughtBox"
  local LABEL_ONE="ThoughtBox AI"
  local DRY="${TB_DRY_RUN:-0}"

  export PATH="$GITA_HOME/bin:$HOME/.local/bin:$PATH"
  # Never let git or Git Credential Manager stop to ask for a password: a
  # missing sign-in must fail with a message, not hang.
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never

  # Questions and sign-in read from the terminal, not from the piped script.
  local TTY=/dev/tty
  if ! { : <"$TTY"; } 2>/dev/null; then TTY=/dev/null; fi

  start_log
  trap on_exit EXIT

  local os asset sha app_dir cli_dir
  case "$(uname -s)" in
    Darwin)
      # hw.optional.arm64, not uname -m, which says x86_64 under Rosetta.
      [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ||
        fail "Gita's gita command is only built for Apple silicon Macs (M1 or later); this Mac has an Intel processor."
      os=macos; asset=gita-macos.zip; sha=$GITA_SHA256_MACOS
      app_dir="$HOME/Applications/gita.app"; cli_dir="$app_dir/Contents/Resources/cli" ;;
    Linux)
      [ "$(uname -m)" = x86_64 ] || fail "Gita is only built for x86_64 Linux (this is $(uname -m))."
      os=linux; asset=gita-linux-x64.tar.gz; sha=$GITA_SHA256_LINUX
      app_dir="$HOME/.local/share/gita"; cli_dir="$app_dir/cli" ;;
    *) fail "Unsupported system $(uname -s). On Windows, use install.ps1." ;;
  esac

  # ---- 1. Prerequisites ----
  say "Checking prerequisites"
  step "Git, curl, GitHub CLI"
  install_packages
  step "Claude Code"
  ensure_claude

  # ---- 2. Gita ----
  step "Gita"
  ensure_gita
  add_to_path "$GITA_HOME/bin"

  # ---- 3. Old GitHub sign-ins ----
  step "Clean-up of old GitHub sign-ins"
  run_cleanup

  # ---- 4. Your accounts ----
  say "Your GitHub accounts"
  step "Gita profiles"
  local default_name name email_io email_one id_io id_one PROFILE_ID PROFILES=""
  default_name=$(git config --global user.name 2>/dev/null || true)
  name=$(ask "Your full name (shown on commits)" "$default_name" "${TB_NAME:-}")
  [ -n "$name" ] || fail "A name is needed."
  email_io=$(ask_email "Your @thoughtbox.io email (projects in thoughtboxhub)" thoughtbox.io "${TB_EMAIL_IO:-}")
  email_one=$(ask_email "Your @thoughtbox.one email (projects in ThoughtBoxFinTechAI)" thoughtbox.one "${TB_EMAIL_ONE:-}")

  ensure_profile "$name" "$email_io" "$LABEL_IO"; id_io=$PROFILE_ID
  ensure_profile "$name" "$email_one" "$LABEL_ONE"; id_one=$PROFILE_ID
  show_profiles
  ok "ready"

  # The AI account first: claude-standards lives in its organization.
  step "Sign-in $email_one"
  ensure_signin "$id_one" "$email_one" "$LABEL_ONE" "$id_io"

  # ---- 5. claude-standards and the company files ----
  if [ "${TB_SKIP_STANDARDS:-0}" = 1 ]; then
    warn "Skipping claude-standards."
    record "claude-standards" "skipped (TB_SKIP_STANDARDS)"
  else
    step "claude-standards"
    ensure_standards
    step "Company account rules"
    say "Telling Gita which organization uses which account"
    import_company thoughtbox.json "$id_io"
    import_company thoughtbox-ai.json "$id_one"
    ok "imported"
  fi

  step "Sign-in $email_io"
  ensure_signin "$id_io" "$email_io" "$LABEL_IO" "$id_one"

  # ---- 6. Claude Code ----
  if [ "${TB_SKIP_STANDARDS:-0}" != 1 ]; then
    step "Claude Code company setup"
    say "Setting up Claude Code with the company standards"
    [ -f "$STANDARDS_DIR/setup.sh" ] || [ "$DRY" = 1 ] ||
      fail "$STANDARDS_DIR has no setup.sh." "It may be an old or incomplete copy. Move the folder away and run this again."
    # No terminal input: it asks nothing, and "claude plugin" crashes when its
    # input is /dev/tty (Bun on macOS: "EINVAL: invalid argument, kqueue").
    TTY=/dev/null change "run the claude-standards setup" bash "$STANDARDS_DIR/setup.sh" ||
      fail "The claude-standards setup failed (its messages are above)." "Fix what it says, then run this again. Finished steps are skipped."
    ok "done"
    connect_claude
  fi

  # ---- 7. Check ----
  step "Gita doctor"
  run_doctor

  print_summary
  echo >&2
  if [ "$DRY" = 1 ]; then
    say "Dry run finished. Nothing was changed."
  elif needs_attention; then
    say "Finished, but some steps need attention (marked above)."
  else
    say "Done."
  fi
  note "Next:"
  note "  1. Open a new terminal (so PATH changes apply)."
  note '  2. Run "claude" and sign in with your company Claude Teams seat.'
  note '  3. Clone projects with "gita clone <address>", so each uses the right account.'
  if [ "${TB_GH_LOGGED_OUT:-0}" = 1 ]; then
    note '  4. GitHub CLI was signed out. If you use it, run "gh auth login" with the right account.'
  fi
}

# ---------------------------------------------------------------- output

say()  { printf '\033[36m==> %s\033[0m\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
has()  { command -v "$1" >/dev/null 2>&1; }
works() { "$@" >/dev/null 2>&1; }   # works git --version: installed AND runs

# fail "what went wrong" ["what to do" ...]: stops the setup.
fail() {
  printf '\033[31mSetup stopped: %s\033[0m\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '    %s\n' "$line" >&2; done
  exit 1
}

# Summary rows: "step|result". Global, so the exit trap can print them.
TB_SUMMARY=()
TB_STEP=""
TB_LOG_FILE=""
TB_TMP=""
step()   { TB_STEP=$1; }
ok() {
  local r=$1
  if [ "${DRY:-0}" = 1 ]; then case $r in *"dry run"*) ;; *) r="$r (dry run)" ;; esac; fi
  TB_SUMMARY+=("$TB_STEP|$r"); TB_STEP=""
}
record() { TB_SUMMARY+=("$1|$2"); }

needs_attention() {
  local r
  for r in "${TB_SUMMARY[@]+"${TB_SUMMARY[@]}"}"; do
    case "${r#*|}" in *failed* | *problem* | *"couldn't"*) return 0 ;; esac
  done
  return 1
}

TB_SUMMARY_SHOWN=0
print_summary() {
  [ "$TB_SUMMARY_SHOWN" = 0 ] && [ ${#TB_SUMMARY[@]} -gt 0 ] || return 0
  TB_SUMMARY_SHOWN=1
  echo >&2
  say "Summary"
  local r
  for r in "${TB_SUMMARY[@]}"; do printf '    %-36s %s\n' "${r%%|*}" "${r#*|}" >&2; done
}

on_exit() {
  local rc=$?
  [ -z "$TB_TMP" ] || rm -rf "$TB_TMP"
  if [ "$rc" -ne 0 ] && [ -n "$TB_STEP" ]; then TB_SUMMARY+=("$TB_STEP|failed"); fi
  print_summary
  if [ "$rc" -ne 0 ]; then
    echo >&2
    note "Fix the problem above and run the same command again. Finished steps are skipped."
  fi
  [ -z "$TB_LOG_FILE" ] || note "Log of this run: $TB_LOG_FILE (send it when asking for help)."
}

# The log holds this run only, readable by you only. No step prints a token.
start_log() {
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

# ---------------------------------------------------------------- input

# Runs a command that changes something, or only prints it in a dry run.
change() {
  local what=$1; shift
  if [ "$DRY" = 1 ]; then note "[dry run] would $what"; return 0; fi
  "$@" <"$TTY" || fail "Couldn't $what (exit $?)." "The messages above say why."
}

ask() {  # prompt default preset
  local answer
  if [ -n "$3" ]; then printf '%s' "$3"; return; fi
  if [ "$TTY" = /dev/null ]; then
    note "$1: ${2:-(none)} (no terminal to ask)"; printf '%s' "$2"; return
  fi
  if [ -n "$2" ]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
  IFS= read -r answer <"$TTY" || true
  printf '%s' "${answer:-$2}"
}

ask_email() {  # prompt domain preset
  local email
  while :; do
    email=$(ask "$1" "" "$3" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$email" in
      *@*@*) ;;
      ?*@"$2") printf '%s' "$email"; return ;;
    esac
    [ -z "$3" ] || fail "$email is not an @$2 address."
    [ "$TTY" != /dev/null ] || fail "No terminal to ask for your @$2 email. Set TB_EMAIL_IO and TB_EMAIL_ONE."
    warn "Please enter your @$2 address."
  done
}

ask_yn() {  # question default(y|n): 0 = yes. Without a terminal, the default.
  local a hint="[Y/n]"
  [ "$2" = n ] && hint="[y/N]"
  if [ "$TTY" = /dev/null ]; then [ "$2" = y ]; return; fi
  printf '    %s %s: ' "$1" "$hint" >&2
  IFS= read -r a <"$TTY" || a=""
  case "$a" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) [ "$2" = y ] ;;
  esac
}

# A free "<path>.backup-<date-time>" name; never overwrites an earlier backup.
backup_name() {
  local b n=2
  b="$1.backup-$(date +%Y%m%d-%H%M%S)"
  while [ -e "$b" ] || [ -L "$b" ]; do b="$1.backup-$(date +%Y%m%d-%H%M%S)-$n"; n=$((n + 1)); done
  printf '%s' "$b"
}

with_timeout() {  # seconds command...: macOS has no timeout(1) unless coreutils is installed
  local s=$1; shift
  if has timeout; then timeout "$s" "$@"
  elif has gtimeout; then gtimeout "$s" "$@"
  else "$@"; fi
}

download() {  # url file
  # GitHub's download servers sometimes answer 5xx for a minute (a CI run hit
  # a 504): retry every error, five times, with a longer wait.
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 \
    --retry 5 --retry-delay 10 --retry-all-errors "$1" -o "$2"
}

# ---------------------------------------------------------------- prerequisites

sudo_run() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif [ "$TTY" = /dev/null ]; then sudo -n "$@"   # no terminal to ask for a password
  else sudo "$@"; fi
}

install_packages() {
  if [ "$os" = macos ]; then
    # /usr/bin/git exists even without the developer tools; it only works with them.
    works git --version ||
      fail "Git is missing or not working." 'Run "xcode-select --install", wait for it to finish, then run this again.'
    note "Git is installed."
    ensure_gh brew
    return
  fi

  # Linux. secret-tool: Gita keeps GitHub tokens in the system keyring.
  local need=() pm="" p
  works git --version || need+=(git)
  works curl --version || need+=(curl)
  has secret-tool || need+=(secret-tool)
  if has apt-get; then pm=apt; elif has dnf; then pm=dnf; elif has pacman; then pm=pacman; fi

  if [ ${#need[@]} -gt 0 ]; then
    [ -n "$pm" ] || fail "Please install ${need[*]} with your package manager, then run this again."
    local pkgs=()
    for p in "${need[@]}"; do pkgs+=("$(pkg_name "$pm" "$p")"); done
    say "Installing ${pkgs[*]} (may ask for your password)"
    pkg_install "$pm" "${pkgs[@]}" ||
      fail "Installing ${pkgs[*]} failed." "The messages above say why. Install them with $pm yourself, then run this again."
    if [ "$DRY" != 1 ]; then
      works git --version || fail "Git was installed but doesn't run." "Run \"git --version\" to see why."
      works curl --version || fail "curl was installed but doesn't run." "Run \"curl --version\" to see why."
      has secret-tool || fail "secret-tool is still missing after installing $(pkg_name "$pm" secret-tool)."
    fi
  else
    note "Git, curl and secret-tool are installed."
  fi
  ensure_gh "$pm"
}

# GitHub CLI is optional (Claude uses it for pull requests).
ensure_gh() {  # installer: brew | apt | dnf | pacman | ""
  if works gh --version; then
    note "GitHub CLI is installed."; ok "already installed"; return
  fi
  has gh && warn "GitHub CLI is installed but doesn't run. Reinstalling it."
  local done=1
  case "$1" in
    "") ;;
    brew) has brew && say "Installing GitHub CLI" && pkg_install brew gh && done=0 ;;
    *) say "Installing GitHub CLI" && pkg_install "$1" "$(pkg_name "$1" gh)" && done=0 ;;
  esac
  if [ "$done" = 0 ] && { [ "$DRY" = 1 ] || works gh --version; }; then
    ok "installed"
  else
    warn "GitHub CLI wasn't installed. Get it from https://cli.github.com if you need it."
    ok "not installed (optional)"
  fi
}

pkg_name() {  # package-manager tool
  case "$1:$2" in
    apt:secret-tool) echo libsecret-tools ;;
    dnf:secret-tool | pacman:secret-tool) echo libsecret ;;
    pacman:gh) echo github-cli ;;
    *) echo "$2" ;;
  esac
}

pkg_install() {  # package-manager packages...
  local pm=$1; shift
  if [ "$DRY" = 1 ]; then note "[dry run] would install $* with $pm"; return 0; fi
  case $pm in
    apt) sudo_run apt-get update -qq <"$TTY" && sudo_run apt-get install -y -qq "$@" <"$TTY" ;;
    dnf) sudo_run dnf install -y "$@" <"$TTY" ;;
    pacman) sudo_run pacman -S --needed --noconfirm "$@" <"$TTY" ;;
    brew) brew install "$@" <"$TTY" ;;
  esac
}

ensure_claude() {
  if works claude --version; then note "Claude Code is installed."; ok "already installed"; return; fi
  if has claude; then
    warn "Claude Code is installed but doesn't run. Reinstalling it."
  fi
  say "Installing Claude Code"
  change "install Claude Code (official installer from claude.ai)" bash -c \
    "set -o pipefail; curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 --retry 3 https://claude.ai/install.sh | bash"
  if [ "$DRY" = 1 ]; then ok "dry run"; return; fi
  hash -r
  works claude --version ||
    fail "Claude Code was installed but doesn't run." \
      'Open a new terminal and run "claude --version". If it still fails, see https://docs.claude.com/en/docs/claude-code/setup.'
  ok "installed"
}

# ---------------------------------------------------------------- Gita

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Prints missing | ok | old:<version> | broken:<exit code>.
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
  if [ "$rc" -ne 0 ]; then echo "broken:$rc"
  elif [ "$out" = "gita $GITA_VERSION" ]; then echo ok
  else echo "old:${out#gita }"; fi
}

broken_reason() {  # exit code
  case $1 in
    app) echo "the gita command inside the Gita app doesn't start" ;;
    137) echo "the system stopped it (Killed: 9)" ;;
    126) echo "it isn't allowed to run" ;;
    127) echo "a file it needs is missing" ;;
    *) echo "it exits with code $1" ;;
  esac
}

ensure_gita() {
  local st; st=$(gita_state)
  case $st in
    ok)
      if [ -z "${TB_GITA_ARCHIVE:-}" ]; then
        note "Gita $GITA_VERSION is installed and runs."; ok "already installed"; return
      fi ;;
    missing) ;;
    old:*) note "Gita ${st#old:} is installed. Updating to $GITA_VERSION." ;;
    broken:*) warn "Gita is installed but doesn't run: $(broken_reason "${st#broken:}"). Reinstalling it." ;;
  esac
  say "Installing Gita $GITA_VERSION"
  if [ "$DRY" = 1 ]; then
    note "[dry run] would download Gita into $app_dir and replace $GITA_HOME/bin and $GITA_HOME/lib"
    ok "dry run"; return
  fi
  wait_for_gita_closed
  install_gita
  verify_gita
  ok "installed $GITA_VERSION"
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

install_gita() {
  local work file url actual
  work=$(mktemp -d) || fail "Couldn't create a temporary folder."
  TB_TMP=$work
  file="$work/$asset"
  if [ -n "${TB_GITA_ARCHIVE:-}" ]; then
    warn "Using the local file $TB_GITA_ARCHIVE (no checksum check)."
    cp "$TB_GITA_ARCHIVE" "$file" || fail "Couldn't read $TB_GITA_ARCHIVE."
  else
    [ -n "$sha" ] || fail "Gita $GITA_VERSION has no pinned checksum in this script yet." "Ask an admin."
    url="https://github.com/$GITA_REPO/releases/download/v$GITA_VERSION/$asset"
    note "Downloading $url"
    download "$url" "$file" ||
      fail "Couldn't download Gita." "Check your internet connection and that github.com opens in your browser, then run this again."
    actual=$(sha256_of "$file")
    [ "$actual" = "$sha" ] ||
      fail "The Gita download doesn't match its pinned checksum (got $actual)." "Nothing was installed. Tell an admin."
    note "Checksum OK."
  fi

  mkdir -p "$work/app"
  if [ "$os" = macos ]; then
    ditto -x -k "$file" "$work/app" || fail "Couldn't unpack the Gita download." "Run this again; if it repeats, tell an admin."
    [ -x "$work/app/gita.app/Contents/Resources/cli/bin/gita" ] || fail "The Gita download has no gita.app." "Tell an admin."
    mkdir -p "$(dirname "$app_dir")"
    rm -rf "$app_dir"
    mv "$work/app/gita.app" "$app_dir"
    fix_macos_cli_signature
  else
    tar -xzf "$file" -C "$work/app" || fail "Couldn't unpack the Gita download." "Run this again; if it repeats, tell an admin."
    [ -x "$work/app/cli/bin/gita" ] || fail "The Gita download has no cli/bin/gita." "Tell an admin."
    mkdir -p "$(dirname "$app_dir")"
    rm -rf "$app_dir"
    mv "$work/app" "$app_dir"
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
  rm -rf "$work"; TB_TMP=""
}

verify_gita() {
  local st; st=$(gita_state)
  case $st in
    ok) note "Installed gita $GITA_VERSION and checked that it runs." ;;
    broken:*) fail "Gita was installed but doesn't run: $(broken_reason "${st#broken:}")." \
      "Run \"$GITA_CLI --version\" to see the error, and send it with the log to an admin." ;;
    old:*) fail "Gita was installed but reports version ${st#old:} instead of $GITA_VERSION." "Tell an admin." ;;
    *) fail "Gita was installed but $GITA_CLI is missing." "Tell an admin." ;;
  esac
}

# Gita 1.0.2's command is signed with the hardened runtime but without the
# entitlement the Dart runtime needs to run its compiled code, so newer macOS
# kills it on start ("Killed: 9"). If the bundled command won't run, sign it
# again (ad hoc) with that entitlement. It is fixed inside gita.app, not just
# in ~/.gita, because the app copies its command to ~/.gita every time it
# starts. Does nothing once a Gita release ships a command that runs.
fix_macos_cli_signature() {
  local exe="$cli_dir/bin/gita" ent f
  { "$exe" --version; } >/dev/null 2>&1 && return 0   # braces: no "Killed: 9" line
  note "Re-signing the gita command so macOS lets it run."
  ent="$work/cli.entitlements"
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
  find "$cli_dir" -type f \( -perm -u+x -o -name '*.dylib' \) | while IFS= read -r f; do
    codesign --force --sign - --options runtime --entitlements "$ent" "$f" 2>/dev/null ||
      fail "Couldn't re-sign $f."
  done
  # Re-seal the app, since files inside it changed, keeping its own entitlements.
  codesign --force --sign - --preserve-metadata=entitlements,flags "$app_dir" 2>/dev/null ||
    fail "Couldn't re-sign $app_dir."
  { "$exe" --version; } >/dev/null 2>&1 ||
    fail "The gita command still won't run on this Mac after re-signing it. Tell an admin."
}

add_to_path() {
  local dir=$1 rc line
  # shellcheck disable=SC2016
  line="export PATH=\"${dir/#$HOME/\$HOME}:\$PATH\""
  # The default shell's file is created if needed; the other is used if present.
  local main_rc="$HOME/.bashrc"
  [ "$os" = macos ] && main_rc="$HOME/.zshrc"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || [ "$rc" = "$main_rc" ] || continue
    grep -qF "$line" "$rc" 2>/dev/null && continue
    if [ "$DRY" = 1 ]; then note "[dry run] would add $dir to PATH in $rc"; continue; fi
    printf '\n# Added by ThoughtBox dev-setup\n%s\n' "$line" >>"$rc" || warn "Couldn't add $dir to PATH in $rc."
  done
}

# ---------------------------------------------------------------- clean-up

# Hides a token that may sit in an address (https://user:token@github.com).
redact() { printf '%s' "$1" | sed -E 's#//[^/@ ]+@#//***@#g'; }

clean_add() {  # description action: skips an action that is already listed
  local a
  for a in "${CLEAN_DO[@]+"${CLEAN_DO[@]}"}"; do [ "$a" = "$2" ] && return 0; done
  CLEAN_LIST+=("$1"); CLEAN_DO+=("$2")
}

# Finds old GitHub sign-ins and settings that can make git or gh use another
# account. Fills CLEAN_LIST/CLEAN_DO (removed after asking) and CLEAN_REPORT
# (only reported). Reads ~/.gitconfig itself, never the files Gita includes.
find_cleanup() {
  CLEAN_LIST=(); CLEAN_DO=(); CLEAN_REPORT=()
  local line k v helpers

  # Saved github.com logins: erased first, while every helper is still configured.
  helpers=$( (cd / && { git config --get-all credential.helper
      git config --global --get-regexp '^credential\..*github\.com.*\.helper$' | cut -d' ' -f2-; }) 2>/dev/null |
    grep -v -e '^$' -e 'gh auth' -e 'gita' | sort -u | tr '\n' ' ' || true)
  if [ -n "$helpers" ] && has_saved_login; then
    case "$helpers" in *password* | *token*) helpers="(a custom helper)" ;; esac
    clean_add "Saved github.com logins in: ${helpers% } (erased with \"git credential reject\")" "reject|"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=${line%% *}; v=${line#* }
    case "$k $v" in *github.com*)
      clean_add "git setting $(redact "$k") = $(redact "$v") (sends github.com addresses somewhere else, e.g. SSH)" "unset|$k" ;;
    esac
  done < <(git config --global --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null || true)

  while IFS= read -r k; do
    [ -n "$k" ] && clean_add "git setting $(redact "$k") (sends a fixed sign-in with every github.com request)" "unset|$k"
  done < <(git config --global --name-only --get-regexp '^http\..*github\.com.*\.extraheader$' 2>/dev/null || true)
  if git config --global --get-all http.extraheader 2>/dev/null | grep -qi '^authorization'; then
    clean_add "git setting http.extraheader (a sign-in header sent to every site, github.com included)" "unset|http.extraheader"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=${line%% *}; v=${line#* }
    case "$v" in *password* | *token* | *=*) v="(a custom command)" ;; esac
    clean_add "git setting $(redact "$k") = $v (an old github.com login helper)" "unset|$k"
  done < <(git config --global --get-regexp '^credential\..*github\.com.*\.helper$' 2>/dev/null || true)

  if has gh; then
    local login
    for login in $( (unset GH_TOKEN GITHUB_TOKEN; with_timeout 30 gh auth status --hostname github.com 2>&1 || true) |
      sed -nE 's/.*Logged in to github\.com (account|as) ([A-Za-z0-9-]+).*/\2/p' | sort -u); do
      clean_add "GitHub CLI login @$login (gh auth logout)" "ghlogout|$login"
    done
  fi

  local var files
  for var in GH_TOKEN GITHUB_TOKEN; do
    files=$(grep -lE "^[[:space:]]*(export[[:space:]]+)?$var=" "$HOME/.bashrc" "$HOME/.bash_profile" \
      "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" 2>/dev/null | tr '\n' ' ' || true)
    if [ -n "${!var:-}" ] || [ -n "$files" ]; then
      CLEAN_REPORT+=("$var is set${files:+ in ${files% }}. gh and other tools use it instead of your sign-in. Remove that line yourself, then open a new terminal.")
    fi
  done
  if [ -f "$HOME/.ssh/config" ] && grep -qiE '^[[:space:]]*host[[:space:]].*github\.com' "$HOME/.ssh/config"; then
    CLEAN_REPORT+=('Your SSH settings file (.ssh/config in your home folder) has a "Host github.com" entry. It only matters for SSH addresses (git@github.com:...) and was not changed.')
  fi
}

run_cleanup() {
  say "Looking for old GitHub sign-ins and settings"
  find_cleanup
  local r i
  for r in "${CLEAN_REPORT[@]+"${CLEAN_REPORT[@]}"}"; do warn "$r"; done
  # This run never uses a token from the environment.
  unset GH_TOKEN GITHUB_TOKEN
  if [ ${#CLEAN_LIST[@]} -eq 0 ]; then
    note "None found."; ok "nothing to clean"; return
  fi
  note "Found these. They can make git or gh use an old GitHub account instead of your Gita sign-in:"
  for i in "${CLEAN_LIST[@]}"; do note "  - $i"; done
  if [ "$DRY" = 1 ]; then note "[dry run] would ask, back up ~/.gitconfig and remove the items above"; ok "dry run"; return; fi
  if [ "${TB_CLEAN:-0}" != 1 ]; then
    if [ "$TTY" = /dev/null ]; then
      warn "No terminal to ask, so nothing was removed. Set TB_CLEAN=1 to remove them."
      ok "kept (no terminal)"; return
    fi
    if ! ask_yn "Remove them? ~/.gitconfig is backed up first. Gita's own sign-ins, other sites and SSH keys are not touched." y; then
      warn "Kept. If cloning later says a project doesn't exist, run this again and answer yes."
      ok "kept (your choice)"; return
    fi
  fi

  if [ -f "$HOME/.gitconfig" ]; then
    local backup
    backup=$(backup_name "$HOME/.gitconfig")
    ( umask 077 && cp "$HOME/.gitconfig" "$backup" ) || fail "Couldn't back up ~/.gitconfig, so nothing was removed."
    note "Backed up ~/.gitconfig to $backup."
  fi

  local a kind arg n=0
  for a in "${CLEAN_DO[@]}"; do
    kind=${a%%|*}; arg=${a#*|}
    case $kind in
      reject) erase_github_logins && n=$((n + 1)) ;;
      unset)
        if git config --global --unset-all "$arg" 2>/dev/null; then n=$((n + 1))
        else warn "Couldn't remove the git setting $(redact "$arg")."; fi ;;
      ghlogout) gh_logout "$arg" && n=$((n + 1)) ;;
    esac
  done
  note "Removed $n of ${#CLEAN_DO[@]}."
  if [ "$n" -eq "${#CLEAN_DO[@]}" ]; then ok "cleaned ($n)"; else ok "cleaned $n of ${#CLEAN_DO[@]} (some failed)"; fi
}

# True if a configured helper holds a github.com login. The answer is
# discarded; askpass is "false" so no window or prompt can appear.
has_saved_login() {
  (cd / && printf 'protocol=https\nhost=github.com\n\n' |
    GIT_ASKPASS=false SSH_ASKPASS=false with_timeout 30 git -c core.askPass=false credential fill) >/dev/null 2>&1
}

# Erases saved github.com logins from every configured helper. Runs from / so
# no repository's settings (or Gita's per-folder rules) take part. Repeated,
# because some helpers erase one saved login per call.
erase_github_logins() {
  local i
  for i in 1 2 3; do
    (cd / && printf 'protocol=https\nhost=github.com\n\n' | with_timeout 30 git credential reject) >/dev/null 2>&1 ||
      { warn "Couldn't erase the saved github.com logins."; return 1; }
  done
}

gh_logout() {  # login
  if env -u GH_TOKEN -u GITHUB_TOKEN gh auth logout --hostname github.com --user "$1" >/dev/null 2>&1 ||
    env -u GH_TOKEN -u GITHUB_TOKEN gh auth logout --hostname github.com <"$TTY"; then
    TB_GH_LOGGED_OUT=1; return 0
  fi
  warn "Couldn't sign GitHub CLI out of @$1. Run \"gh auth logout\" yourself."
  return 1
}

# ---------------------------------------------------------------- profiles and sign-in

# Loads one "id<TAB>email<TAB>signedIn<TAB>githubLogin" line per profile into PROFILES.
load_profiles() {
  PROFILES=""
  [ -x "$GITA_CLI" ] || return 0
  local json rc=0
  json=$("$GITA_CLI" profiles --json 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Gita couldn't list its profiles (exit $rc)." \
    "Run \"$GITA_CLI profiles\" to see the error. If Gita doesn't run, run this setup again to reinstall it."
  PROFILES=$(printf '%s\n' "$json" | awk -F'"' '
    $2 == "id"          { id = $4; login = "" }
    $2 == "email"       { email = $4 }
    $2 == "githubLogin" { login = $4 }
    $2 == "signedIn"    { si = ($3 ~ /true/) ? "true" : "false"; print id "\t" email "\t" si "\t" login }')
}

profile_get() {  # id field(2=email 3=signedIn 4=login)
  printf '%s\n' "$PROFILES" | awk -F'\t' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'
}

ensure_profile() {  # name email label -> PROFILE_ID
  local out rc=0
  load_profiles
  PROFILE_ID=$(printf '%s\n' "$PROFILES" | awk -F'\t' -v e="$2" '$2 == e { print $1; exit }')
  if [ -n "$PROFILE_ID" ]; then note "Profile for $2 already exists."; return; fi
  if [ "$DRY" = 1 ]; then note "[dry run] would add the Gita profile \"$3\" for $2"; PROFILE_ID="<$3>"; return; fi
  out=$("$GITA_CLI" profile add --name "$1" --email "$2" --label "$3" --json 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Couldn't add the Gita profile for $2 (exit $rc)." "$out"
  PROFILE_ID=$(printf '%s' "$out" | awk -F'"' '$2 == "id" { print $4; exit }')
  [ -n "$PROFILE_ID" ] || fail "Gita added the profile for $2 but didn't say its id." "Run \"gita profiles\" and tell an admin."
  note "Added the Gita profile \"$3\" for $2."
}

show_profiles() {
  load_profiles
  [ -n "$PROFILES" ] || return 0
  local id email si login
  while IFS="$(printf '\t')" read -r id email si login; do
    if [ "$si" = true ]; then note "$email: signed in to GitHub as @${login:-unknown}"
    else note "$email: not signed in to GitHub yet"; fi
  done <<<"$PROFILES"
}

# An existing sign-in is kept only if it is the right account: the developer
# confirms the login, and it must differ from the other profile's login.
ensure_signin() {  # id email label other-id
  local id=$1 email=$2 label=$3 other=$4
  if [ "${TB_SKIP_SIGNIN:-0}" = 1 ]; then warn "Skipping GitHub sign-in for $email."; ok "skipped (TB_SKIP_SIGNIN)"; return; fi
  load_profiles
  local login other_login
  login=$(profile_get "$id" 4); other_login=$(profile_get "$other" 4)
  if [ "$(profile_get "$id" 3)" = true ]; then
    if [ -n "$login" ] && [ "$login" = "$other_login" ] && [ "$(profile_get "$other" 3)" = true ]; then
      warn "Both of your Gita profiles are signed in as @$login. One GitHub account can't be both your @thoughtbox.io and @thoughtbox.one account, so \"$label\" is signed in again."
    elif ask_yn "\"$label\" is signed in to GitHub as @${login:-unknown}. Is that your GitHub account for $email?" y; then
      note "Keeping that sign-in."; ok "already signed in as @${login:-unknown}"; return
    fi
  fi
  signin_flow "$id" "$email" "$label" "$other"
  if [ "$DRY" = 1 ]; then ok "dry run"; return; fi
  load_profiles
  ok "signed in as @$(profile_get "$id" 4)"
}

signin_flow() {  # id email label other-id: signs in, confirms the account, one retry
  local id=$1 email=$2 label=$3 other=$4 try login other_login
  for try in 1 2; do
    say "Sign in to GitHub with the account for $email"
    note "A code is shown below. Enter it on github.com while signed in as your $email GitHub account."
    note "GitHub signs in whoever is logged in to github.com in your browser. If that is your other account, sign out there first (or use a private window)."
    if [ "$DRY" = 1 ]; then note "[dry run] would sign in \"$label\" to GitHub"; return 0; fi
    "$GITA_CLI" sign-in --profile "$id" <"$TTY" ||
      fail "Signing in $email to GitHub failed." "Run this again. If it keeps failing, check that github.com opens in your browser."
    load_profiles
    login=$(profile_get "$id" 4); other_login=$(profile_get "$other" 4)
    if [ -n "$login" ] && [ "$login" = "$other_login" ]; then
      warn "That is @$login, the account your other profile already uses."
    elif ask_yn "Signed in as @${login:-unknown}. Is that your GitHub account for $email?" y; then
      return 0
    fi
    [ "$try" = 2 ] || warn "Let's sign in again. First sign out of github.com in your browser (or open a private window), then sign in as your $email account."
  done
  fail "\"$label\" is still not signed in with your $email GitHub account." \
    "In your browser, sign out of github.com and sign in as your $email account. Then run:" \
    "  gita sign-in --profile \"$label\"" \
    "and run this setup again."
}

# ---------------------------------------------------------------- claude-standards

norm_url() {  # any GitHub address form -> github.com/owner/repo, lower case
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -E 's#^(https?|ssh|git)://##; s#^[^@/]+@##; s#^github\.com:#github.com/#; s#/+$##; s#\.git$##'
}

# Prints clean | dirty | move:<reason>.
standards_state() {
  local d=$STANDARDS_DIR url
  [ -d "$d" ] || { echo "move:not a folder"; return; }
  [ -n "$(ls -A "$d" 2>/dev/null)" ] || { echo "move:empty"; return; }
  [ -e "$d/.git" ] || { echo "move:not a git copy"; return; }
  url=$(git -C "$d" config --get remote.origin.url 2>/dev/null || true)
  [ "$(norm_url "$url")" = "$(norm_url "$STANDARDS_URL")" ] || { echo "move:a copy of a different project"; return; }
  local status
  status=$(git -C "$d" status --porcelain 2>/dev/null) || { echo "move:a damaged git copy"; return; }
  if [ -n "$status" ]; then echo dirty; else echo clean; fi
}

ensure_standards() {
  local d=$STANDARDS_DIR
  if [ -e "$d" ] || [ -L "$d" ]; then
    local st; st=$(standards_state)
    case $st in
      clean)
        say "Updating claude-standards"
        if [ "$DRY" = 1 ]; then note "[dry run] would update $d (git pull --ff-only)"; ok "dry run"; return; fi
        # BatchMode: an SSH address must fail, not stop at a host-key or passphrase prompt.
        if (cd "$d" && GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" with_timeout 180 git -c advice.diverging=false pull --ff-only -q); then
          note "claude-standards is up to date."; ok "updated"
        else
          warn "Couldn't update claude-standards (the message above says why). Using the copy you have."
          ok "kept (update failed)"
        fi
        return ;;
      dirty)
        warn "claude-standards in $d has local changes, so it was not updated."
        ok "kept (local changes)"; return ;;
      move:*)
        # Never deleted: moved aside with a timestamp.
        local backup
        backup=$(backup_name "$d")
        warn "$d is ${st#move:}. Moving it to $backup and downloading a fresh copy."
        change "move $d to $backup" mv "$d" "$backup" ;;
    esac
  fi
  clone_standards
}

clone_standards() {
  say "Downloading claude-standards"
  if [ "$DRY" = 1 ]; then note "[dry run] would clone claude-standards into $STANDARDS_DIR"; ok "dry run"; return; fi
  local try login
  for try in 1 2; do
    if "$GITA_CLI" clone "$STANDARDS_URL" "$STANDARDS_DIR" --profile "$id_one" <"$TTY"; then
      ok "downloaded"; return 0
    fi
    # The folder did not exist before this clone, so anything left is a partial copy.
    rm -rf "${STANDARDS_DIR:?}"
    load_profiles
    login=$(profile_get "$id_one" 4)
    warn "Couldn't download claude-standards. Likely causes:"
    note "  1. ThoughtBoxFinTechAI hasn't approved the Gita app yet (the most common cause). On"
    note "     github.com open Settings > Applications > Authorized OAuth Apps > Gita, click"
    note "     \"Request\" next to ThoughtBoxFinTechAI, and ask an org owner to approve it under"
    note "     Organization settings > Third-party access."
    note "  2. \"$LABEL_ONE\" is signed in as @${login:-unknown}. It must be your $email_one GitHub account,"
    note "     the one that is a member of ThoughtBoxFinTechAI."
    note "  3. Your account hasn't been added to ThoughtBoxFinTechAI yet. Ask an admin."
    note "  4. No connection to github.com."
    if [ "$try" != 1 ] || [ "$TTY" = /dev/null ] || [ "${TB_SKIP_SIGNIN:-0}" = 1 ]; then break; fi
    ask_yn "Sign \"$LABEL_ONE\" in to GitHub again and retry?" y || break
    signin_flow "$id_one" "$email_one" "$LABEL_ONE" "$id_io"
  done
  fail "claude-standards couldn't be downloaded." "Check the causes listed above, then run this again."
}

import_company() {  # file profile-id
  local f="$STANDARDS_DIR/gita/$1"
  if [ "$DRY" = 1 ]; then note "[dry run] would import gita/$1"; return 0; fi
  [ -f "$f" ] || fail "claude-standards has no gita/$1." "It may be an old copy. Run \"git -C $STANDARDS_DIR pull\", then run this again."
  "$GITA_CLI" company import "$f" --profile "$2" ||
    fail "Gita couldn't import gita/$1 (the message above says why)." "Run this again; if it repeats, send the log to an admin."
}

connect_claude() {
  step "Gita in Claude Code"
  if [ "$DRY" = 1 ]; then note "[dry run] would connect Gita to Claude Code"; ok "dry run"; return; fi
  if ! works claude --version; then
    warn 'Claude Code is not on PATH yet, so Gita was not connected to it. Open a new terminal and run "gita mcp add-to-claude".'
    ok "couldn't connect (run gita mcp add-to-claude)"; return
  fi
  if "$GITA_CLI" mcp add-to-claude <"$TTY"; then
    ok "connected"
  else
    warn 'Couldn'"'"'t connect Gita to Claude Code. Close Claude Code, then run "gita mcp add-to-claude".'
    ok "failed (run gita mcp add-to-claude)"
  fi
}

run_doctor() {
  say "Checking the setup"
  if [ "$DRY" = 1 ]; then note "[dry run] would run gita doctor"; ok "dry run"; return; fi
  local out rc=0
  out=$("$GITA_CLI" doctor 2>&1 <"$TTY") || rc=$?
  printf '%s\n' "$out" >&2
  case $rc in
    # Exit 0 can still carry "Heads up" notes (not blocking).
    0) case $out in *"Heads up"*) ok "ok, with notes (above)" ;; *) ok "all good" ;; esac ;;
    1) warn 'Gita found problems (listed above). Run "gita doctor --fix", or follow the advice it printed.'
       ok "problems found (run gita doctor --fix)" ;;
    *) warn "gita doctor couldn't run (exit $rc)."; ok "couldn't run (exit $rc)" ;;
  esac
}

main "$@"
