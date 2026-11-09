#!/usr/bin/env bash
# ThoughtBox developer setup for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.sh | bash
#
# Installs Git, GitHub CLI, Claude Code and Gita, sets up your two GitHub
# accounts (@thoughtbox.io and @thoughtbox.one), clones claude-standards and
# runs its setup. Safe to run again: steps that are already done are skipped.
#
# Optional environment variables (set them before running, e.g. TB_DRY_RUN=1 bash):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_GITA_ARCHIVE=<path>  install Gita from a local archive (testing, no checksum)
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_SKIP_STANDARDS=1 skip claude-standards and the Claude Code setup (testing)
#   TB_FIGMA=1 / TB_FIGMA=0  set up the Figma MCP Bridge for frontend work (macOS),
#                       or skip it, without being asked (default: ask; no terminal = skip)

# Everything is inside main, so a half-downloaded script runs nothing.
main() {
  set -euo pipefail

  # ---- Pinned versions. Update with every Gita release (see README). ----
  local GITA_REPO="naseebnaushad/gita"
  local GITA_VERSION="1.0.2"
  local GITA_SHA256_MACOS="49b6a17a0920e66ccadc2a26b7caa241f7ce0ecdf28cd8d9f8f91b077e6b01d7"   # SHA-256 of gita-macos.zip
  local GITA_SHA256_LINUX="f7736ddc106d0293b1feaeb3494c0ba3645b9ebec5b0ef2cfc1cc0c501122cdc"   # SHA-256 of gita-linux-x64.tar.gz

  # ---- Pinned Figma MCP Bridge (optional step). Update together (see README). ----
  local FIGMA_VERSION="0.0.25"
  local FIGMA_NPM_SHA512="e4d49e8aed1cea7e18f42222ae4e854901341c9824e4f12c3a63b85d6abd61bfa16fc3ac39e7dda596bcb83440f26233ebc47fc6f458390967f6d85ed9aedb8a"   # SHA-512 of the npm tarball
  local FIGMA_PLUGIN_SHA256="bf50a9ce330193bceb916c0eeb7252ce72a696f92a3369528139b6a4376d8550"   # SHA-256 of the release zip
  local FIGMA_DIR="$HOME/.thoughtbox/figma-mcp-bridge"

  local STANDARDS_URL="https://github.com/ThoughtBoxFinTechAI/claude-standards.git"
  local STANDARDS_DIR="$HOME/claude-standards"
  local GITA_HOME="$HOME/.gita"
  local GITA_CLI="$GITA_HOME/bin/gita"
  local LABEL_IO="ThoughtBox"
  local LABEL_ONE="ThoughtBox AI"
  local DRY="${TB_DRY_RUN:-0}"

  export PATH="$GITA_HOME/bin:$HOME/.local/bin:$PATH"

  # Questions and sign-in read from the terminal, not from the piped script.
  local TTY=/dev/tty
  if ! { : <"$TTY"; } 2>/dev/null; then TTY=/dev/null; fi

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
  install_packages

  if has claude; then
    note "Claude Code is installed."
  else
    say "Installing Claude Code"
    change "install Claude Code (official installer from claude.ai)" \
      bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  fi

  # ---- 2. Gita ----
  local installed=""
  [ -x "$GITA_CLI" ] && installed=$({ "$GITA_CLI" --version; } 2>/dev/null || true)
  # The Mac app copies its own command over ~/.gita when it starts, so the
  # copy inside gita.app has to run too (see fix_macos_cli_signature).
  if [ "$os" = macos ] && ! { "$cli_dir/bin/gita" --version; } >/dev/null 2>&1; then
    installed=""
  fi
  if [ "$installed" = "gita $GITA_VERSION" ] && [ -z "${TB_GITA_ARCHIVE:-}" ]; then
    note "Gita $GITA_VERSION is installed."
  else
    say "Installing Gita $GITA_VERSION"
    if [ "$DRY" = 1 ]; then
      note "[dry run] would download and install Gita into $app_dir"
    else
      install_gita
    fi
  fi
  add_to_path "$GITA_HOME/bin"

  # ---- 3. Your accounts ----
  say "Your GitHub accounts"
  local default_name name email_io email_one id_io id_one
  default_name=$(git config --global user.name 2>/dev/null || true)
  name=$(ask "Your full name (shown on commits)" "$default_name" "${TB_NAME:-}")
  [ -n "$name" ] || fail "A name is needed."
  email_io=$(ask_email "Your @thoughtbox.io email (projects in thoughtboxhub)" thoughtbox.io "${TB_EMAIL_IO:-}")
  email_one=$(ask_email "Your @thoughtbox.one email (projects in ThoughtBoxFinTechAI)" thoughtbox.one "${TB_EMAIL_ONE:-}")

  id_io=$(ensure_profile "$name" "$email_io" "$LABEL_IO")
  id_one=$(ensure_profile "$name" "$email_one" "$LABEL_ONE")

  # The AI account first: claude-standards lives in its organization.
  ensure_signin "$id_one" "$email_one"

  # ---- 4. claude-standards and the company files ----
  if [ "${TB_SKIP_STANDARDS:-0}" = 1 ]; then
    warn "Skipping claude-standards."
  else
    if [ -d "$STANDARDS_DIR/.git" ]; then
      note "claude-standards is already in $STANDARDS_DIR."
    else
      say "Downloading claude-standards"
      change "clone claude-standards into $STANDARDS_DIR" \
        "$GITA_CLI" clone "$STANDARDS_URL" "$STANDARDS_DIR" --profile "$id_one"
    fi
    say "Telling Gita which organization uses which account"
    change "import gita/thoughtbox.json" \
      "$GITA_CLI" company import "$STANDARDS_DIR/gita/thoughtbox.json" --profile "$id_io"
    change "import gita/thoughtbox-ai.json" \
      "$GITA_CLI" company import "$STANDARDS_DIR/gita/thoughtbox-ai.json" --profile "$id_one"
  fi

  ensure_signin "$id_io" "$email_io"

  # ---- 5. Claude Code ----
  if [ "${TB_SKIP_STANDARDS:-0}" != 1 ]; then
    say "Setting up Claude Code with the company standards"
    # No terminal input: it asks nothing, and "claude plugin" crashes when its
    # input is /dev/tty (Bun on macOS: "EINVAL: invalid argument, kqueue").
    TTY=/dev/null change "run the claude-standards setup" bash "$STANDARDS_DIR/setup.sh"
  fi
  if [ "${TB_SKIP_STANDARDS:-0}" = 1 ]; then
    :
  elif has claude; then
    change "connect Gita to Claude Code" "$GITA_CLI" mcp add-to-claude
  else
    warn 'Claude Code is not on PATH yet, so Gita was not connected to it. Run "gita mcp add-to-claude" later.'
  fi

  # ---- 6. Optional: Figma for frontend work ----
  local figma=no
  if want_figma; then
    if [ "$os" != macos ]; then
      note "Figma for frontend work is skipped: the Figma desktop app (which the bridge needs) isn't available on Linux."
    else
      say "Setting up Figma for frontend work"
      # A subshell, so a "Setup stopped" inside only ends this optional step.
      if (install_figma_bridge); then
        figma=yes
      else
        warn "The Figma step didn't finish (see the message above). Everything else is set up."
        warn "Fix that and run the setup again with TB_FIGMA=1."
      fi
    fi
  fi

  # ---- 7. Check ----
  say "Checking the setup"
  [ "$DRY" = 1 ] || "$GITA_CLI" doctor || true

  echo
  say "Done."
  note "Next:"
  note "  1. Open a new terminal (so PATH changes apply)."
  note '  2. Run "claude" and sign in with your company Claude Teams seat.'
  note '  3. Clone projects with "gita clone <address>", so each uses the right account.'
  if [ "$figma" = yes ]; then
    note "  4. Figma, once: open the Figma desktop app, then Plugins > Development >"
    note "     Import plugin from manifest... and pick:"
    note "       $FIGMA_DIR/plugin/manifest.json"
    note '     Then open the shared Figma file, run "Figma MCP Bridge" from'
    note "     Plugins > Development, and start (or restart) claude."
  fi
}

say()  { printf '\033[36m==> %s\033[0m\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[31mSetup stopped: %s\033[0m\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

# Runs a command that changes something, or only prints it in a dry run.
change() {
  local what=$1; shift
  if [ "$DRY" = 1 ]; then note "[dry run] would $what"; return 0; fi
  "$@" <"$TTY" || fail "$what failed."
}

ask() {  # prompt default preset
  local answer
  if [ -n "$3" ]; then printf '%s' "$3"; return; fi
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

sudo_run() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif [ "$TTY" = /dev/null ]; then sudo -n "$@"   # no terminal to ask for a password
  else sudo "$@"; fi
}

install_packages() {
  if [ "$os" = macos ]; then
    has git || fail 'Git is missing. Run "xcode-select --install", wait for it to finish, then run this again.'
    note "Git is installed."
    if has gh; then
      note "GitHub CLI is installed."
    elif has brew; then
      say "Installing GitHub CLI"
      change "install GitHub CLI with Homebrew" brew install gh
    else
      warn "Homebrew isn't installed, so GitHub CLI was skipped. Get it from https://cli.github.com if you need it."
    fi
    return
  fi

  # Linux. secret-tool: Gita keeps GitHub tokens in the system keyring.
  local need=() pm="" p
  has git || need+=(git)
  has curl || need+=(curl)
  has secret-tool || need+=(secret-tool)
  if has apt-get; then pm=apt; elif has dnf; then pm=dnf; elif has pacman; then pm=pacman; fi

  if [ ${#need[@]} -gt 0 ]; then
    [ -n "$pm" ] || fail "Please install ${need[*]} with your package manager, then run this again."
    local pkgs=()
    for p in "${need[@]}"; do pkgs+=("$(pkg_name "$pm" "$p")"); done
    say "Installing ${pkgs[*]} (may ask for your password)"
    pkg_install "$pm" "${pkgs[@]}" || fail "Installing ${pkgs[*]} failed."
  else
    note "Git, curl and secret-tool are installed."
  fi

  if has gh; then
    note "GitHub CLI is installed."
  elif [ -n "$pm" ] && say "Installing GitHub CLI" && pkg_install "$pm" "$(pkg_name "$pm" gh)"; then
    :
  else
    warn "GitHub CLI wasn't installed. Get it from https://cli.github.com if you need it."
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
  esac
}

# GitHub's release downloads sometimes answer 502/503/504 for a while, so try
# three times before giving up.
download() {  # url file
  local try
  for try in 1 2 3; do
    curl -fsSL --max-time 120 "$1" -o "$2" && return 0
    [ "$try" = 3 ] && return 1
    warn "Download failed; trying again in $((try * 10)) seconds."
    sleep $((try * 10))
  done
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

install_gita() {
  local work file url actual
  work=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  file="$work/$asset"
  if [ -n "${TB_GITA_ARCHIVE:-}" ]; then
    warn "Using the local file $TB_GITA_ARCHIVE (no checksum check)."
    cp "$TB_GITA_ARCHIVE" "$file"
  else
    [ -n "$sha" ] || fail "Gita $GITA_VERSION has no pinned checksum in this script yet. Ask an admin."
    url="https://github.com/$GITA_REPO/releases/download/v$GITA_VERSION/$asset"
    note "Downloading $url"
    download "$url" "$file" || fail "Couldn't download Gita."
    actual=$(sha256_of "$file")
    [ "$actual" = "$sha" ] ||
      fail "The Gita download doesn't match its pinned checksum (got $actual). Nothing was installed. Tell an admin."
    note "Checksum OK."
  fi

  mkdir -p "$work/app"
  if [ "$os" = macos ]; then
    ditto -x -k "$file" "$work/app"
    [ -x "$work/app/gita.app/Contents/Resources/cli/bin/gita" ] || fail "The Gita download has no gita.app."
    mkdir -p "$(dirname "$app_dir")"
    rm -rf "$app_dir"
    mv "$work/app/gita.app" "$app_dir"
    fix_macos_cli_signature
  else
    tar -xzf "$file" -C "$work/app"
    [ -x "$work/app/cli/bin/gita" ] || fail "The Gita download has no cli/bin/gita."
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
  local d
  for d in bin lib; do
    [ -d "$cli_dir/$d" ] || continue
    mkdir -p "$GITA_HOME/$d"
    cp -R "$cli_dir/$d/." "$GITA_HOME/$d/"
  done
  chmod +x "$GITA_CLI"
  local version
  version=$("$GITA_CLI" --version 2>/dev/null) ||
    fail "Gita was installed but its gita command won't run on this system. Tell an admin."
  note "Installed $version."
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
    printf '\n# Added by ThoughtBox dev-setup\n%s\n' "$line" >>"$rc"
  done
}

# Prints one "id<TAB>email<TAB>signedIn" line per Gita profile.
list_profiles() {
  [ -x "$GITA_CLI" ] || return 0
  "$GITA_CLI" profiles --json | awk -F'"' '
    $2 == "id"       { id = $4 }
    $2 == "email"    { email = $4 }
    $2 == "signedIn" { si = ($3 ~ /true/) ? "true" : "false"; print id "\t" email "\t" si }'
}

ensure_profile() {  # name email label -> prints id
  local id out
  id=$(list_profiles | awk -F'\t' -v e="$2" '$2 == e { print $1; exit }')
  if [ -n "$id" ]; then note "Profile for $2 already exists."; printf '%s' "$id"; return; fi
  if [ "$DRY" = 1 ]; then note "[dry run] would add the Gita profile \"$3\" for $2"; printf '<%s>' "$3"; return; fi
  out=$("$GITA_CLI" profile add --name "$1" --email "$2" --label "$3" --json) ||
    fail "Couldn't add the Gita profile for $2. $out"
  note "Added the Gita profile \"$3\" for $2."
  printf '%s' "$out" | awk -F'"' '$2 == "id" { print $4; exit }'
}

ensure_signin() {  # id email
  if [ "${TB_SKIP_SIGNIN:-0}" = 1 ]; then warn "Skipping GitHub sign-in for $2."; return; fi
  if list_profiles | awk -F'\t' -v i="$1" '$1 == i && $3 == "true" { f = 1 } END { exit !f }'; then
    note "$2 is already signed in to GitHub."; return
  fi
  say "Sign in to GitHub with the account for $2"
  note "A code is shown below. Enter it on github.com, signed in as the account for this email."
  note "If the browser is signed in to your other account, sign out there first."
  change "sign in $2 to GitHub" "$GITA_CLI" sign-in --profile "$1"
}

# ---- Optional: Figma MCP Bridge (see the README) ----

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
    has brew || fail 'Node.js 20 or later is needed. Install Homebrew (https://brew.sh) or Node.js LTS (https://nodejs.org), then run this again.'
    say "Installing Node.js"
    change "install Node.js with Homebrew" brew install node
    if [ "$DRY" != 1 ] && [ "$(node_major)" -lt 20 ]; then
      fail 'Node.js 20 or later is needed, but "node --version" still shows an older one (or none). Switch with your version manager, or remove the old Node.js, and run this again.'
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
    fail "The Figma bridge is running. Close Claude Code (and any other AI tool using it), then run this again."
  fi
  work=$(mktemp -d) || fail "Couldn't make a temporary folder."
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  note "Downloading @gethopp/figma-mcp-bridge@$FIGMA_VERSION from npm"
  (cd "$work" && npm pack "@gethopp/figma-mcp-bridge@$FIGMA_VERSION" --silent >/dev/null </dev/null) ||
    fail "Couldn't download the bridge server from npm."
  tgz=$(find "$work" -maxdepth 1 -name '*.tgz' | head -n 1)
  [ -n "$tgz" ] || fail "npm didn't produce the bridge server package."
  actual=$(sha512_of "$tgz")
  [ "$actual" = "$FIGMA_NPM_SHA512" ] ||
    fail "The bridge server download doesn't match its pinned checksum. Nothing was installed. Tell an admin."

  zip="$work/plugin.zip"
  url="https://github.com/gethopp/figma-mcp-bridge/releases/download/v$FIGMA_VERSION/figma-mcp-bridge-v$FIGMA_VERSION.zip"
  note "Downloading $url"
  download "$url" "$zip" || fail "Couldn't download the Figma plugin."
  actual=$(sha256_of "$zip")
  [ "$actual" = "$FIGMA_PLUGIN_SHA256" ] ||
    fail "The Figma plugin download doesn't match its pinned checksum. Nothing was installed. Tell an admin."
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
