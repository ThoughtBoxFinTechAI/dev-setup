# ThoughtBox developer setup for Windows.
#
#   irm https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.ps1 | iex
#
# Installs Git, GitHub CLI, Claude Code and Gita, sets up your two GitHub
# accounts (@thoughtbox.io and @thoughtbox.one), clones claude-standards and
# runs its setup. Safe to run again: steps that are already done are skipped.
#
# Optional environment variables (set them before running):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_GITA_ZIP=<path>  install Gita from a local zip (testing, no checksum)
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_SKIP_STANDARDS=1 skip claude-standards and the Claude Code setup (testing)
#   TB_FIGMA=1 / TB_FIGMA=0  set up the Figma MCP Bridge for frontend work, or skip
#                       it, without being asked (default: ask; no terminal = skip)

# Everything is inside a function, so a half-downloaded script runs nothing.
function Install-ThoughtBoxDevSetup {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2

  # ---- Pinned versions. Update with every Gita release (see README). ----
  $GitaRepo    = 'naseebnaushad/gita'
  $GitaVersion = '1.0.2'
  $GitaAsset   = 'gita-windows-x64.zip'
  $GitaSha256  = 'd73ba7b9a1e34498e32432b6e73eb3d9007bb1cab1b51cc292a351b0d7d4334d'   # SHA-256 of $GitaAsset for $GitaVersion

  # ---- Pinned Figma MCP Bridge (optional step). Update together (see README). ----
  $FigmaVersion      = '0.0.25'
  $FigmaNpmSha512    = 'e4d49e8aed1cea7e18f42222ae4e854901341c9824e4f12c3a63b85d6abd61bfa16fc3ac39e7dda596bcb83440f26233ebc47fc6f458390967f6d85ed9aedb8a'   # SHA-512 of the npm tarball
  $FigmaPluginSha256 = 'bf50a9ce330193bceb916c0eeb7252ce72a696f92a3369528139b6a4376d8550'   # SHA-256 of the release zip
  $FigmaDir          = Join-Path $HOME '.thoughtbox\figma-mcp-bridge'

  $StandardsUrl ='https://github.com/ThoughtBoxFinTechAI/claude-standards.git'
  $StandardsDir = Join-Path $HOME 'claude-standards'
  $GitaHome     = Join-Path $HOME '.gita'
  $GitaCli      = Join-Path $GitaHome 'bin\gita.exe'
  $GitaAppDir   = Join-Path $env:LOCALAPPDATA 'Programs\Gita'
  $LabelIo      = 'ThoughtBox'
  $LabelOne     = 'ThoughtBox AI'

  $Dry = $env:TB_DRY_RUN -eq '1'

  function Say([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
  function Note([string]$Text) { Write-Host "    $Text" }
  function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }
  function Fail([string]$Text) { throw "Setup stopped: $Text" }

  # Runs a step that changes something, or only prints it in a dry run.
  function Change([string]$What, [scriptblock]$Do) {
    if ($Dry) { Note "[dry run] would $What"; return }
    & $Do
  }

  function Has([string]$Cmd) { [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

  # GitHub's release downloads sometimes answer 502/503/504 for a while, so try
  # up to five times, waiting longer each time (10 s up to 40 s), before giving up.
  function Get-Download([string]$Url, [string]$OutFile) {
    $ProgressPreference = 'SilentlyContinue'
    for ($try = 1; ; $try++) {
      try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
        return
      } catch {
        if ($try -ge 5) { throw }
        Warn "Download failed ($($_.Exception.Message)); trying again in $($try * 10) seconds."
        Start-Sleep -Seconds ($try * 10)
      }
    }
  }

  # Picks up PATH changes made by installers, without a new terminal.
  function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user, (Join-Path $GitaHome 'bin'), (Join-Path $HOME '.local\bin')) |
      Where-Object { $_ }) -join ';'
  }

  function Add-UserPath([string]$Dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -contains $Dir) { return }
    Change "add $Dir to your PATH" {
      [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'User')
    }
  }

  # Runs a native command and stops the setup if it fails.
  function Run([string]$What, [scriptblock]$Do) {
    if ($Dry) { Note "[dry run] would $What"; return }
    & $Do
    if ($LASTEXITCODE -ne 0) { Fail "$What failed (exit $LASTEXITCODE)." }
  }

  function Ask([string]$Prompt, [string]$Default, [string]$Preset) {
    if ($Preset) { return $Preset.Trim() }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if (-not $answer) { $answer = $Default }
    return "$answer".Trim()
  }

  function Ask-Email([string]$Prompt, [string]$Domain, [string]$Preset) {
    while ($true) {
      $email = (Ask $Prompt '' $Preset).ToLowerInvariant()
      if ($email -match "^[^@\s]+@$([regex]::Escape($Domain))$") { return $email }
      if ($Preset) { Fail "$email is not an @$Domain address." }
      Warn "Please enter your @$Domain address."
    }
  }

  function Get-Profiles {
    if (-not (Test-Path $GitaCli)) { return @() }
    $json = & $GitaCli profiles --json | Out-String
    if ($LASTEXITCODE -ne 0) { Fail 'gita profiles failed.' }
    return @(($json | ConvertFrom-Json).profiles)
  }

  # Returns the id of the profile for this email, adding one if needed.
  function Ensure-Profile([string]$Name, [string]$Email, [string]$Label) {
    $found = @(Get-Profiles | Where-Object { $_.email -eq $Email })
    if ($found.Count -gt 0) {
      Note "Profile for $Email already exists (`"$($found[0].label)`")."
      return $found[0].id
    }
    if ($Dry) { Note "[dry run] would add the Gita profile `"$Label`" for $Email"; return "<$Label>" }
    $out = & $GitaCli profile add --name $Name --email $Email --label $Label --json | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "Couldn't add the Gita profile for $Email. $out" }
    Note "Added the Gita profile `"$Label`" for $Email."
    return ($out | ConvertFrom-Json).profile.id
  }

  function Ensure-SignIn([string]$Id, [string]$Email) {
    if ($env:TB_SKIP_SIGNIN -eq '1') { Warn "Skipping GitHub sign-in for $Email."; return }
    $p = @(Get-Profiles | Where-Object { $_.id -eq $Id })
    if ($p.Count -gt 0 -and $p[0].signedIn) { Note "$Email is already signed in to GitHub."; return }
    Say "Sign in to GitHub with the account for $Email"
    Note 'A code is shown below. Enter it on github.com, signed in as the account for this email.'
    Note 'If the browser is signed in to your other account, sign out there first.'
    Run "sign in $Email to GitHub" { & $GitaCli sign-in --profile $Id }
  }

  # ---- Optional: Figma MCP Bridge (see the README) ----

  # TB_FIGMA answers up front; otherwise ask. No terminal to ask in means no.
  function Want-Figma {
    if ($env:TB_FIGMA -eq '1') { return $true }
    if ($env:TB_FIGMA -eq '0') { return $false }
    if ($env:TB_FIGMA) { Warn "TB_FIGMA must be 1 or 0 (it is `"$env:TB_FIGMA`"), so the Figma step is skipped."; return $false }
    $nonInteractive = [Environment]::GetCommandLineArgs() | Where-Object { $_ -like '-NonI*' }
    if ([Console]::IsInputRedirected -or $nonInteractive) { return $false }
    $answer = "$(Read-Host 'Set up Figma for frontend work (Figma MCP Bridge)? [y/N]')".Trim().ToLowerInvariant()
    return ($answer -eq 'y' -or $answer -eq 'yes')
  }

  # Runs a native command whose stderr is only noise. Windows PowerShell turns
  # any stderr line into a terminating error under 'Stop', even with 2>$null.
  function Invoke-Native([scriptblock]$Do) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Do 2>$null } finally { $ErrorActionPreference = $old }
  }

  function Get-NodeMajor {
    if (-not (Has 'node')) { return 0 }
    $v = "$(node --version 2>$null)".Trim()
    if ($v -match '^v(\d+)\.') { return [int]$Matches[1] }
    return 0
  }

  # The bridge's command line points into this folder, so a running copy locks it.
  function Get-BridgeProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like "*$FigmaDir*" })
  }

  # Throws (with "Setup stopped:") on a problem; the caller turns that into a warning.
  function Install-FigmaBridge {
    if (-not (Has 'winget')) { Fail 'winget is needed for this step. Install "App Installer" from the Microsoft Store.' }

    # Node.js runs the bridge server (it needs 20 or later).
    if ((Get-NodeMajor) -ge 20) {
      Note "Node.js $(node --version) is installed."
    } else {
      Say 'Installing Node.js LTS'
      Run 'install Node.js LTS' {
        winget install --id OpenJS.NodeJS.LTS --exact --source winget --silent --accept-package-agreements --accept-source-agreements
      }
      Update-SessionPath
      if (-not $Dry -and (Get-NodeMajor) -lt 20) {
        Fail 'Node.js 20 or later is needed, but "node --version" still shows an older one (or none). Remove the old Node.js (or switch with your version manager) and run this again.'
      }
    }

    # The plugin runs only in the Figma desktop app, not in the browser.
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe')) {
      Note 'The Figma desktop app is installed.'
    } else {
      Say 'Installing the Figma desktop app'
      if ($Dry) {
        Note '[dry run] would install the Figma desktop app'
      } else {
        winget install --id Figma.Figma --exact --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Warn 'The Figma desktop app was not installed. Get it from https://www.figma.com/downloads/.' }
      }
    }

    # Bridge server and plugin, both checked against the pinned checksums.
    $entry = Join-Path $FigmaDir 'server\node_modules\@gethopp\figma-mcp-bridge\dist\index.js'
    $manifest = Join-Path $FigmaDir 'plugin\manifest.json'
    $marker = Join-Path $FigmaDir 'version'
    $current = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '' }
    if ($current -eq $FigmaVersion -and (Test-Path $entry) -and (Test-Path $manifest)) {
      Note "Figma MCP Bridge $FigmaVersion is installed."
    } else {
      Say "Installing Figma MCP Bridge $FigmaVersion"
      Change "download and install Figma MCP Bridge into $FigmaDir" {
        if (@(Get-BridgeProcesses).Count -gt 0) {
          Fail 'The Figma bridge is running. Close Claude Code (and any other AI tool using it), then run this again.'
        }
        $work = Join-Path ([IO.Path]::GetTempPath()) ("tb-figma-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
          $ProgressPreference = 'SilentlyContinue'

          # npm.cmd, not npm: npm.ps1 can be blocked by the execution policy.
          Note "Downloading @gethopp/figma-mcp-bridge@$FigmaVersion from npm"
          Invoke-Native { npm.cmd pack "@gethopp/figma-mcp-bridge@$FigmaVersion" --pack-destination $work --silent } | Out-Null
          if ($LASTEXITCODE -ne 0) { Fail "Couldn't download the bridge server from npm." }
          $tgz = @(Get-ChildItem $work -Filter '*.tgz')
          if ($tgz.Count -ne 1) { Fail "npm didn't produce the bridge server package." }
          $actual = (Get-FileHash $tgz[0].FullName -Algorithm SHA512).Hash
          if ($actual -ne $FigmaNpmSha512.ToUpperInvariant()) {
            Fail "The bridge server download doesn't match its pinned checksum. Nothing was installed. Tell an admin."
          }

          $zip = Join-Path $work 'plugin.zip'
          $url = "https://github.com/gethopp/figma-mcp-bridge/releases/download/v$FigmaVersion/figma-mcp-bridge-v$FigmaVersion.zip"
          Note "Downloading $url"
          Get-Download $url $zip
          $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
          if ($actual -ne $FigmaPluginSha256.ToUpperInvariant()) {
            Fail "The Figma plugin download doesn't match its pinned checksum. Nothing was installed. Tell an admin."
          }
          Note 'Checksums OK.'

          # Build the new copy next to the downloads, then swap it in.
          $stage = Join-Path $work 'bridge'
          $server = Join-Path $stage 'server'
          New-Item -ItemType Directory -Path $server -Force | Out-Null
          Invoke-Native { npm.cmd install --prefix $server $tgz[0].FullName --ignore-scripts --omit=dev --no-audit --no-fund --silent } | Out-Null
          if ($LASTEXITCODE -ne 0) { Fail "Couldn't install the bridge server's packages with npm." }
          Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'zip')
          $plugin = Join-Path $work 'zip\plugin'
          if (-not (Test-Path (Join-Path $plugin 'manifest.json'))) { Fail 'The Figma plugin download has no plugin\manifest.json.' }
          Move-Item $plugin (Join-Path $stage 'plugin')
          Set-Content -Path (Join-Path $stage 'version') -Value $FigmaVersion -Encoding ascii

          if (Test-Path $FigmaDir) { Remove-Item $FigmaDir -Recurse -Force }
          New-Item -ItemType Directory -Path (Split-Path $FigmaDir) -Force | Out-Null
          Move-Item $stage $FigmaDir
        } finally {
          Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        }
        Note "Installed Figma MCP Bridge $FigmaVersion."
      }
    }

    # Claude Code entry. run_script is on by team decision (CR-0.1.0-02, D5).
    if (-not (Has 'claude')) {
      Warn 'Claude Code is not on PATH yet, so the bridge was not added to it. Run this setup again in a new terminal.'
      return
    }
    if ($Dry) { Note '[dry run] would add figma-bridge to Claude Code'; return }
    $node = (Get-Command node).Source
    $existing = "$(Invoke-Native { claude mcp get figma-bridge })"
    if ($LASTEXITCODE -eq 0 -and $existing.Contains($entry) -and $existing.Contains($node) -and
        $existing.Contains('FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1')) {
      Note 'figma-bridge is already in Claude Code.'
      return
    }
    Invoke-Native { claude mcp remove figma-bridge --scope user } | Out-Null
    # '--' quoted: Windows PowerShell drops a bare -- before native commands.
    Invoke-Native { claude mcp add figma-bridge --scope user --env FIGMA_BRIDGE_ENABLE_RUN_SCRIPT=1 '--' $node $entry } | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Adding figma-bridge to Claude Code failed.' }
    Note 'Added figma-bridge to Claude Code.'
  }

  # ---- 1. Prerequisites ----
  Say 'Checking prerequisites'
  if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Windows 10 or later is needed.' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Update-SessionPath

  $winget = @(
    @{ Cmd = 'git'; Id = 'Git.Git'; Name = 'Git for Windows' },
    @{ Cmd = 'gh'; Id = 'GitHub.cli'; Name = 'GitHub CLI' }
  )
  foreach ($w in $winget) {
    if (Has $w.Cmd) { Note "$($w.Name) is installed."; continue }
    if (-not (Has 'winget')) {
      Fail "$($w.Name) is missing and winget isn't available. Install `"App Installer`" from the Microsoft Store, then run this again."
    }
    Say "Installing $($w.Name)"
    Run "install $($w.Name)" {
      winget install --id $w.Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    }
    Update-SessionPath
  }

  if (Has 'claude') {
    Note 'Claude Code is installed.'
  } else {
    Say 'Installing Claude Code'
    Change 'install Claude Code (official installer from claude.ai)' {
      Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    }
    Update-SessionPath
  }

  # ---- 2. Gita ----
  $installed = ''
  if (Test-Path $GitaCli) { $installed = "$(& $GitaCli --version 2>$null)".Trim() }
  if ($installed -eq "gita $GitaVersion" -and -not $env:TB_GITA_ZIP) {
    Note "Gita $GitaVersion is installed."
  } else {
    Say "Installing Gita $GitaVersion"
    $work = Join-Path ([IO.Path]::GetTempPath()) ("tb-gita-" + [guid]::NewGuid())
    Change "download and install Gita into $GitaAppDir" {
      New-Item -ItemType Directory -Path $work | Out-Null
      try {
        $zip = Join-Path $work $GitaAsset
        if ($env:TB_GITA_ZIP) {
          Warn "Using the local file $env:TB_GITA_ZIP (no checksum check)."
          Copy-Item $env:TB_GITA_ZIP $zip
        } else {
          if (-not $GitaSha256) { Fail "Gita $GitaVersion has no pinned checksum in this script yet. Ask an admin." }
          $url = "https://github.com/$GitaRepo/releases/download/v$GitaVersion/$GitaAsset"
          Note "Downloading $url"
          $ProgressPreference = 'SilentlyContinue'
          Get-Download $url $zip
          $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
          if ($actual -ne $GitaSha256.ToUpperInvariant()) {
            Fail "The Gita download doesn't match its pinned checksum (got $actual). Nothing was installed. Tell an admin."
          }
          Note 'Checksum OK.'
        }
        $unpacked = Join-Path $work 'app'
        Expand-Archive -Path $zip -DestinationPath $unpacked
        if (-not (Test-Path (Join-Path $unpacked 'cli\bin\gita.exe'))) { Fail 'The Gita download has no cli\bin\gita.exe.' }

        Get-Process gita -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$GitaAppDir*" } |
          ForEach-Object { Fail 'Gita is open. Close it and run this again.' }
        if (Test-Path $GitaAppDir) { Remove-Item $GitaAppDir -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path $GitaAppDir) -Force | Out-Null
        Move-Item $unpacked $GitaAppDir

        # Same layout the Gita app keeps: ~/.gita/bin and ~/.gita/lib. Git runs
        # the credential helper from here, so this path must not change.
        foreach ($d in 'bin', 'lib') {
          $src = Join-Path $GitaAppDir "cli\$d"
          if (-not (Test-Path $src)) { continue }
          $dst = Join-Path $GitaHome $d
          New-Item -ItemType Directory -Path $dst -Force | Out-Null
          Copy-Item (Join-Path $src '*') $dst -Recurse -Force
        }

        # Start menu shortcut to the Gita app. Nice to have, so never fatal.
        try {
          $programs = [Environment]::GetFolderPath('Programs')
          if ($programs) {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'Gita.lnk'))
            $lnk.TargetPath = Join-Path $GitaAppDir 'gita.exe'
            $lnk.WorkingDirectory = $GitaAppDir
            $lnk.Save()
          }
        } catch { Warn "Couldn't add Gita to the Start menu: $($_.Exception.Message)" }
      } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
      }
      Note "Installed $(& $GitaCli --version)."
    }
  }
  Add-UserPath (Join-Path $GitaHome 'bin')
  Update-SessionPath

  # ---- 3. Your accounts ----
  Say 'Your GitHub accounts'
  $defaultName = ''
  if (Has 'git') { $defaultName = "$(git config --global user.name 2>$null)".Trim() }
  $name = Ask 'Your full name (shown on commits)' $defaultName $env:TB_NAME
  if (-not $name) { Fail 'A name is needed.' }
  $emailIo = Ask-Email 'Your @thoughtbox.io email (projects in thoughtboxhub)' 'thoughtbox.io' $env:TB_EMAIL_IO
  $emailOne = Ask-Email 'Your @thoughtbox.one email (projects in ThoughtBoxFinTechAI)' 'thoughtbox.one' $env:TB_EMAIL_ONE

  $idIo = Ensure-Profile $name $emailIo $LabelIo
  $idOne = Ensure-Profile $name $emailOne $LabelOne

  # The AI account first: claude-standards lives in its organization.
  Ensure-SignIn $idOne $emailOne

  # ---- 4. claude-standards and the company files ----
  if ($env:TB_SKIP_STANDARDS -eq '1') {
    Warn 'Skipping claude-standards.'
  } else {
    if (Test-Path (Join-Path $StandardsDir '.git')) {
      Note "claude-standards is already in $StandardsDir."
    } else {
      Say 'Downloading claude-standards'
      Run "clone claude-standards into $StandardsDir" {
        & $GitaCli clone $StandardsUrl $StandardsDir --profile $idOne
      }
    }
    Say 'Telling Gita which organization uses which account'
    Run 'import gita/thoughtbox.json' {
      & $GitaCli company import (Join-Path $StandardsDir 'gita\thoughtbox.json') --profile $idIo
    }
    Run 'import gita/thoughtbox-ai.json' {
      & $GitaCli company import (Join-Path $StandardsDir 'gita\thoughtbox-ai.json') --profile $idOne
    }
  }

  Ensure-SignIn $idIo $emailIo

  # ---- 5. Claude Code ----
  if ($env:TB_SKIP_STANDARDS -ne '1') {
    Say 'Setting up Claude Code with the company standards'
    Run 'run the claude-standards setup' {
      powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $StandardsDir 'setup.ps1')
    }
  }
  if ($env:TB_SKIP_STANDARDS -eq '1') {
  } elseif (Has 'claude') {
    Run 'connect Gita to Claude Code' { & $GitaCli mcp add-to-claude }
  } else {
    Warn 'Claude Code is not on PATH yet, so Gita was not connected to it. Run "gita mcp add-to-claude" later.'
  }

  # ---- 6. Optional: Figma for frontend work ----
  $figma = 'no'
  if (Want-Figma) {
    Say 'Setting up Figma for frontend work'
    try {
      Install-FigmaBridge
      $figma = 'yes'
    } catch {
      # Optional step: say what went wrong and finish the rest of the setup.
      Warn "The Figma step didn't finish: $($_.Exception.Message -replace '^Setup stopped: ', '')"
      Warn 'Everything else is set up. Fix that and run the setup again with TB_FIGMA=1.'
      $figma = 'failed'
    }
  }

  # ---- 7. Check ----
  Say 'Checking the setup'
  if (-not $Dry) { & $GitaCli doctor }

  Write-Host ''
  Say 'Done.'
  Note 'Next:'
  Note '  1. Open a new terminal (so PATH changes apply).'
  Note '  2. Run "claude" and sign in with your company Claude Teams seat.'
  Note '  3. Clone projects with "gita clone <address>", so each uses the right account.'
  if ($figma -eq 'yes') {
    Note '  4. Figma, once: open the Figma desktop app, then Plugins > Development >'
    Note '     Import plugin from manifest... and pick:'
    Note "       $(Join-Path $FigmaDir 'plugin\manifest.json')"
    Note '     Then open the shared Figma file, run "Figma MCP Bridge" from'
    Note '     Plugins > Development, and start (or restart) claude.'
  }
}

try {
  Install-ThoughtBoxDevSetup
} catch {
  Write-Host ''
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host 'Fix the problem above and run the same command again. Finished steps are skipped.'
}
