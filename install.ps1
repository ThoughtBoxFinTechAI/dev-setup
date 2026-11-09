# ThoughtBox developer setup for Windows.
#
#   irm https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.ps1 | iex
#
# Installs or updates Gita (a pinned release, checked against its SHA-256),
# downloads the ThoughtBox onboarding file (also checked), and runs
# "gita onboard" with it. Gita does the rest: Git, GitHub CLI and Claude Code,
# clean-up of old GitHub sign-ins, your two GitHub accounts (@thoughtbox.io and
# @thoughtbox.one), claude-standards and its setup, Gita in Claude Code, and a
# final check with a summary. Safe to run again: finished steps are skipped.
#
# Optional environment variables (set them before running, e.g. $env:TB_DRY_RUN = '1'):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_CLEAN=1          remove old GitHub sign-ins and settings without asking
#   TB_LOG=<path>       write the log here instead of ~\.thoughtbox-setup.log
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_SKIP_STANDARDS=1 skip claude-standards and its setup (testing)
#   TB_GITA_ZIP=<path>         install Gita from a local zip (testing, no checksum)
#   TB_ONBOARDING_FILE=<path>  use a local onboarding file (testing, no checksum)
#   TB_FIGMA=1 / TB_FIGMA=0  set up the Figma MCP Bridge for frontend work, or skip
#                       it, without being asked (default: ask; no terminal = skip)
#   TB_TEST_USER_PATH_FILE=<path>  read and write the user PATH in this file instead
#                       of the registry (testing)
#   TB_TEST_MACHINE_PATH=<value>   use this as the system PATH (testing, read only)

# Everything is inside a function, so a half-downloaded script runs nothing.
function Install-ThoughtBoxDevSetup {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2

  # ---- Pinned versions. The gita-bump workflow updates these lines. ----
  $GitaRepo = 'naseebnaushad/gita'
  $GitaVersion = '1.1.1'
  $GitaAsset = 'gita-windows-x64.zip'
  # Checksum: filled in by the gita-bump workflow PR.
  $GitaSha256 = '095a36bdac7c8fa914209a8300db3a55ee09e01cc52971a8293222a534e2e018'   # SHA-256 of $GitaAsset for $GitaVersion
  $OnboardingUrl = 'https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/thoughtbox-onboarding.json'
  $OnboardingSha256 = 'a723840dd6b09911fea6b1afa42cfe641c21deb161d0cb66e3e9e6bf1431a196'

  # ---- Pinned Figma MCP Bridge (optional step). Update together (see README). ----
  $FigmaVersion      = '0.0.25'
  $FigmaNpmSha512    = 'e4d49e8aed1cea7e18f42222ae4e854901341c9824e4f12c3a63b85d6abd61bfa16fc3ac39e7dda596bcb83440f26233ebc47fc6f458390967f6d85ed9aedb8a'   # SHA-512 of the npm tarball
  $FigmaPluginSha256 = 'bf50a9ce330193bceb916c0eeb7252ce72a696f92a3369528139b6a4376d8550'   # SHA-256 of the release zip
  $FigmaDir          = Join-Path $HOME '.thoughtbox\figma-mcp-bridge'

  $GitaHome   = Join-Path $HOME '.gita'
  $GitaCli    = Join-Path $GitaHome 'bin\gita.exe'
  $GitaAppDir = Join-Path $env:LOCALAPPDATA 'Programs\Gita'
  $Dry        = $env:TB_DRY_RUN -eq '1'

  # Questions need a real console; without one, defaults are used.
  $Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' })

  # Shared state (an object, so the helper functions below can change it).
  $S = @{ Log = ''; Tmp = ''; Code = 0; Notes = New-Object System.Collections.ArrayList }

  function Say([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
  function Note([string]$Text) { Write-Host "    $Text" }
  function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }
  # Fail "what went wrong" "what to do"...: stops the setup.
  function Fail([string]$Text, [string[]]$Hints = @()) {
    $msg = "Setup stopped: $Text"
    foreach ($h in $Hints) { $msg += "`n    $h" }
    throw $msg
  }

  # The log holds this run only and is readable by you only. No step prints a token.
  function Start-Log {
    $path = if ($env:TB_LOG) { $env:TB_LOG } else { Join-Path $HOME '.thoughtbox-setup.log' }
    try {
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
      New-Item -ItemType File -Path $path -Force | Out-Null
      $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      & icacls.exe $path /inheritance:r /grant:r "*${sid}:(F)" | Out-Null
      Start-Transcript -LiteralPath $path -Append | Out-Null
      $S.Log = $path
      Note "ThoughtBox dev-setup, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), Windows $([Environment]::OSVersion.Version)"
    } catch {
      Warn "Couldn't create the log file ${path}; carrying on without it."
    }
  }

  # Yes/no question; without a terminal, the default.
  function Ask-YN([string]$Question, [bool]$Default) {
    if (-not $Interactive) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "    $Question $hint"
    if ($a -match '^[Yy]') { return $true }
    if ($a -match '^[Nn]') { return $false }
    return $Default
  }

  # Runs a native command quietly; returns @{ Code; Out }. PowerShell 5.1 turns
  # a native program's error output into errors, so errors only stop it later.
  function Capture([scriptblock]$Do) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $out = & $Do 2>&1 | ForEach-Object { "$_" }
      return @{ Code = $LASTEXITCODE; Out = (@($out) -join "`n") }
    } catch {
      return @{ Code = 9009; Out = $_.Exception.Message }
    } finally { $ErrorActionPreference = $old }
  }

  function Record([string]$Text) { [void]$S.Notes.Add($Text) }   # a line for the script's short summary

  # The user PATH as stored, with %VARIABLES% kept (the registry value is
  # REG_EXPAND_SZ). TB_TEST_USER_PATH_FILE points it at a file for tests.
  function Get-UserPathRaw {
    if ($env:TB_TEST_USER_PATH_FILE) {
      if (Test-Path -LiteralPath $env:TB_TEST_USER_PATH_FILE) { return [IO.File]::ReadAllText($env:TB_TEST_USER_PATH_FILE).Trim() }
      return ''
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return '' }
    try { return [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
  }

  function Set-UserPathRaw([string]$Value) {
    if ($env:TB_TEST_USER_PATH_FILE) { [IO.File]::WriteAllText($env:TB_TEST_USER_PATH_FILE, $Value); return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $key.Close() }
    # Tells Windows (and new terminals) that the environment changed.
    [Environment]::SetEnvironmentVariable('TB_DEV_SETUP_REFRESH', $null, 'User')
  }

  # Entries of the system or user PATH, with %VARIABLES% expanded.
  function Get-PathEntries([string]$Scope) {
    $raw = if ($Scope -eq 'User') { Get-UserPathRaw }
      elseif ($env:TB_TEST_MACHINE_PATH) { $env:TB_TEST_MACHINE_PATH }
      else { [Environment]::GetEnvironmentVariable('Path', 'Machine') }
    return @("$raw" -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
  }

  function Test-SameDir([string]$A, [string]$B) {
    return [Environment]::ExpandEnvironmentVariables($A).TrimEnd('\') -eq $B.TrimEnd('\')
  }

  # Picks up PATH changes made by installers, without a new terminal. Keeps
  # this session's own entries first and adds the new ones after them.
  function Update-SessionPath {
    $machine = (Get-PathEntries 'Machine') -join ';'
    $user = (Get-PathEntries 'User') -join ';'
    $all = New-Object System.Collections.ArrayList
    foreach ($p in (@($env:Path, $machine, $user, (Join-Path $GitaHome 'bin')) -join ';') -split ';') {
      if ($p -and -not ($all -contains $p)) { [void]$all.Add($p) }
    }
    $env:Path = $all -join ';'
  }

  # Makes ~\.gita\bin the first entry of the user PATH (moved, never doubled),
  # so another gita in the user PATH can't run instead of Gita's.
  function Set-GitaFirstInUserPath {
    $dir = Join-Path $GitaHome 'bin'
    $raw = Get-UserPathRaw
    $parts = @("$raw" -split ';' | Where-Object { $_ })
    $rest = @($parts | Where-Object { -not (Test-SameDir $_ $dir) })
    $new = (@($dir) + $rest) -join ';'
    if ($new -eq ($parts -join ';')) { return }
    $what = if ($rest.Count -lt $parts.Count) { 'Moved ~\.gita\bin to the front of your user PATH' } else { 'Added ~\.gita\bin to the front of your user PATH' }
    if ($Dry) { Note "[dry run] would put $dir first in your user PATH"; Record "$what (dry run)"; return }
    Set-UserPathRaw $new
    Record $what
  }

  # Another gita.exe or gita.cmd on PATH would run instead of Gita's. Windows
  # puts the system PATH before the user PATH, so one there needs an admin.
  function Find-OtherGita {
    $dir = Join-Path $GitaHome 'bin'
    $seen = @{}
    foreach ($scope in 'Machine', 'User') {
      foreach ($d in Get-PathEntries $scope) {
        if ((Test-SameDir $d $dir) -or $seen.ContainsKey($d.ToLowerInvariant())) { continue }
        $seen[$d.ToLowerInvariant()] = $true
        foreach ($name in 'gita.exe', 'gita.cmd') {
          $p = Join-Path $d $name
          if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
          if ($scope -eq 'Machine') {
            Warn "Another gita is at $p, in the system PATH, which Windows puts before your own PATH, so it runs instead of Gita's."
            Note "Remove it, or ask IT to remove $d from the system PATH."
            Record "Another gita at $p runs first (system PATH; remove it or ask IT)"
          } else {
            Warn "Another gita is at $p. ~\.gita\bin is now first in your user PATH, so it is behind Gita's; open a new terminal."
            Note "You can remove it if you don't need it."
            if ($Dry) { Record "Another gita at $p would be behind ~\.gita\bin (dry run)" } else { Record "Another gita at $p is now behind ~\.gita\bin" }
          }
        }
      }
    }
  }

  function Get-WithRetry([string]$Url, [string]$OutFile, [string]$What) {
    $ProgressPreference = 'SilentlyContinue'
    # GitHub's release downloads sometimes fail for a moment (a CI run hit
    # a 504): five tries, waiting longer each time.
    for ($i = 1; $i -le 5; $i++) {
      try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300; return }
      catch {
        if ($i -eq 5) {
          Fail "Couldn't download ${What}: $($_.Exception.Message)" @('Check your internet connection and that github.com opens in your browser, then run this again.')
        }
        Start-Sleep -Seconds (5 * $i)
      }
    }
  }

  function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

  # Compares dotted version numbers as numbers, ignoring anything after "-".
  # Returns 1 if A is newer, -1 if older, 0 if the same.
  function Compare-Version([string]$A, [string]$B) {
    $x = @(($A -replace '-.*$', '') -split '\.'); $y = @(($B -replace '-.*$', '') -split '\.')
    for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
      [long]$p = 0; [long]$q = 0
      if ($i -lt $x.Count) { [void][long]::TryParse(($x[$i] -replace '\D', ''), [ref]$p) }
      if ($i -lt $y.Count) { [void][long]::TryParse(($y[$i] -replace '\D', ''), [ref]$q) }
      if ($p -gt $q) { return 1 }
      if ($p -lt $q) { return -1 }
    }
    return 0
  }

  # missing | ok | older:<version> | newer:<version> | broken:<reason code>
  function Get-GitaState {
    if (-not (Test-Path -LiteralPath $GitaCli)) { return 'missing' }
    $r = Capture { & $GitaCli --version }
    if ($r.Code -ne 0) { return "broken:$($r.Code)" }
    if ($r.Out.Trim() -notmatch '^gita (\d\S*)$') { return 'broken:version' }
    $v = $Matches[1]
    switch (Compare-Version $v $GitaVersion) { 0 { return 'ok' } 1 { return "newer:$v" } default { return "older:$v" } }
  }

  function Broken-Reason([string]$Code) {
    switch ($Code) {
      'version'     { return "it doesn't say its version" }
      '-1073741515' { return 'a file it needs is missing (0xC0000135)' }
      '9009'        { return "Windows couldn't start it" }
      default       { return "it exits with code $Code" }
    }
  }

  # Windows can't replace a program while it runs: Gita, and the Gita helper
  # that Claude Code starts, must be closed first.
  function Close-Gita {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $p = $null; try { $p = $_.Path } catch { }
        $p -and ($p -like "$GitaAppDir\*" -or $p -like "$GitaHome\bin\*")
      })
    if ($procs.Count -eq 0) { return }
    Warn "Gita is running ($($procs.Count) process(es), for example the Gita app or Claude Code's Gita connection)."
    if (-not (Ask-YN 'Close them now? Save your work in Claude Code first.' $true)) {
      Fail 'Gita is still running.' @('Close the Gita app and Claude Code, then run this again.')
    }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }

  # Gets the Gita release (or the local zip) into <temp>\app and checks it.
  function Get-Gita {
    $zip = Join-Path $S.Tmp $GitaAsset
    if ($env:TB_GITA_ZIP) {
      Warn "Using the local file $env:TB_GITA_ZIP (no checksum check)."
      Copy-Item -LiteralPath $env:TB_GITA_ZIP $zip
    } else {
      if (-not $GitaSha256) { Fail "Gita $GitaVersion has no pinned checksum in this script yet." @('Ask an admin.') }
      $url = "https://github.com/$GitaRepo/releases/download/v$GitaVersion/$GitaAsset"
      Note "Downloading $url"
      Get-WithRetry $url $zip 'Gita'
      if ((Get-Sha256 $zip) -ne $GitaSha256.ToLowerInvariant()) {
        Fail "The Gita download doesn't match its pinned checksum." @('Nothing was installed. Tell an admin.')
      }
      Note 'Checksum OK.'
    }
    $app = Join-Path $S.Tmp 'app'
    try { Expand-Archive -Path $zip -DestinationPath $app }
    catch { Fail "Couldn't unpack the Gita download: $($_.Exception.Message)" @('Run this again; if it repeats, tell an admin.') }
    if (-not (Test-Path (Join-Path $app 'cli\bin\gita.exe'))) { Fail 'The Gita download has no cli\bin\gita.exe.' @('Tell an admin.') }
    return $app
  }

  function Install-Gita([string]$Unpacked) {
    Say "Installing Gita $GitaVersion"
    Close-Gita
    try {
      if (Test-Path -LiteralPath $GitaAppDir) { Remove-Item -LiteralPath $GitaAppDir -Recurse -Force }
      New-Item -ItemType Directory -Path (Split-Path $GitaAppDir) -Force | Out-Null
      Move-Item -LiteralPath $Unpacked $GitaAppDir
      # Same layout the Gita app keeps: ~/.gita/bin and ~/.gita/lib. Git runs
      # the credential helper from here, so this path must not change.
      # Delete first, then copy, so no old file is left behind. Only bin and
      # lib are replaced; profiles and settings in ~/.gita stay.
      foreach ($d in 'bin', 'lib') {
        $dst = Join-Path $GitaHome $d
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        $src = Join-Path $GitaAppDir "cli\$d"
        if (-not (Test-Path -LiteralPath $src)) { continue }
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item (Join-Path $src '*') $dst -Recurse -Force
      }
    } catch {
      Fail "Couldn't replace the Gita files: $($_.Exception.Message)" @('Close the Gita app and Claude Code (or restart Windows), then run this again.')
    }
    # Start menu shortcut to the Gita app. Nice to have, so never fatal.
    try {
      $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
      New-Item -ItemType Directory -Path $programs -Force | Out-Null
      $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'Gita.lnk'))
      $lnk.TargetPath = Join-Path $GitaAppDir 'gita.exe'
      $lnk.WorkingDirectory = $GitaAppDir
      $lnk.Save()
    } catch { Warn "Couldn't add Gita to the Start menu: $($_.Exception.Message)" }
  }

  function Test-Gita {
    $st = Get-GitaState
    if ($st -eq 'ok') { Note "Gita $GitaVersion is installed and runs."; return }
    if ($st -like 'older:*' -or $st -like 'newer:*') {
      $v = $st.Substring($st.IndexOf(':') + 1)
      # A local test build may carry another version number.
      if (-not $env:TB_GITA_ZIP) { Fail "Gita was installed but reports version $v instead of $GitaVersion." @('Tell an admin.') }
      Warn "The local file holds Gita $v, not $GitaVersion."; return
    }
    if ($st -like 'broken:*') {
      Fail "Gita was installed but doesn't run: $(Broken-Reason $st.Substring(7))." @("Run `"$GitaCli --version`" to see the error, and send it with the log to an admin.")
    }
    Fail "Gita was installed but $GitaCli is missing." @('Tell an admin.')
  }

  # Returns the gita.exe to run: the installed one, or in a dry run the
  # downloaded copy in the temporary folder (a dry run installs nothing).
  function Use-Gita {
    Say 'Gita'
    $st = Get-GitaState
    if (-not $env:TB_GITA_ZIP) {
      if ($st -eq 'ok') { Note "Gita $GitaVersion is installed and runs."; return $GitaCli }
      if ($st -like 'newer:*') { Note "Gita $($st.Substring(6)) is newer than this script's $GitaVersion; keeping it."; return $GitaCli }
    }
    if ($st -like 'older:*') { Note "Gita $($st.Substring(6)) is installed. Updating to $GitaVersion." }
    if ($st -like 'broken:*') { Warn "Gita is installed but doesn't run: $(Broken-Reason $st.Substring(7)). Reinstalling it." }
    $app = Get-Gita
    if ($Dry) {
      Note "[dry run] would install Gita $GitaVersion into $GitaAppDir and $GitaHome"
      return (Join-Path $app 'cli\bin\gita.exe')
    }
    Install-Gita $app
    Test-Gita
    return $GitaCli
  }

  function Get-OnboardingFile {
    $file = Join-Path $S.Tmp 'thoughtbox-onboarding.json'
    if ($env:TB_ONBOARDING_FILE) {
      Warn "Using the local onboarding file $env:TB_ONBOARDING_FILE (no checksum check)."
      try { Copy-Item -LiteralPath $env:TB_ONBOARDING_FILE $file } catch { Fail "Couldn't read $env:TB_ONBOARDING_FILE." }
      return $file
    }
    Get-WithRetry $OnboardingUrl $file 'the onboarding file'
    if ((Get-Sha256 $file) -ne $OnboardingSha256) {
      Fail "The onboarding file doesn't match its pinned checksum." @('Nothing was changed by it. Tell an admin.')
    }
    return $file
  }

  # Runs "gita onboard" and keeps its exit code in $S.Code. Gita only asks
  # questions when its input and output are a console, so with one it writes
  # straight to it (this function's output must not be captured for that).
  function Invoke-Onboard([string]$Gita, [string]$File) {
    $ga = @('onboard', $File)
    if ($env:TB_NAME) { $ga += @('--name', $env:TB_NAME) }
    if ($env:TB_EMAIL_IO) { $ga += @('--email', "io=$env:TB_EMAIL_IO") }
    if ($env:TB_EMAIL_ONE) { $ga += @('--email', "one=$env:TB_EMAIL_ONE") }
    if ($Dry) { $ga += '--dry-run' }
    if ($env:TB_CLEAN -eq '1') { $ga += '--clean' }
    if ($env:TB_SKIP_SIGNIN -eq '1') { $ga += '--skip-sign-in' }
    if ($env:TB_SKIP_STANDARDS -eq '1') { $ga += '--skip-repos' }
    Write-Host ''
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      if ($Interactive -and -not [Console]::IsOutputRedirected) {
        Note "(Gita's own output is shown in the console only, so it can ask you questions.)"
        & $Gita @ga
      } else {
        & $Gita @ga 2>&1 | ForEach-Object { Write-Host "$_" }
      }
      $S.Code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
  }


  # ------------------------------------------------------------ Figma (optional, see the README)

  function Has([string]$Cmd) { [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

  # TB_FIGMA answers up front; otherwise ask. No console to ask in means no.
  function Want-Figma {
    if ($env:TB_FIGMA -eq '1') { return $true }
    if ($env:TB_FIGMA -eq '0') { return $false }
    if ($env:TB_FIGMA) { Warn "TB_FIGMA must be 1 or 0 (it is `"$env:TB_FIGMA`"), so the Figma step is skipped."; return $false }
    if (-not $Interactive) { return $false }
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
    $v = "$(Invoke-Native { node --version })".Trim()
    if ($v -match '^v(\d+)\.') { return [int]$Matches[1] }
    return 0
  }

  # The bridge's command line points into this folder, so a running copy locks it.
  function Get-BridgeProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like "*$FigmaDir*" })
  }

  function Install-FigmaFiles {
    if (@(Get-BridgeProcesses).Count -gt 0) {
      Fail 'The Figma bridge is running.' @('Close Claude Code (and any other AI tool using it), then run this again.')
    }
    $work = Join-Path $S.Tmp 'figma'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # npm.cmd, not npm: npm.ps1 can be blocked by the execution policy.
    Note "Downloading @gethopp/figma-mcp-bridge@$FigmaVersion from npm"
    Invoke-Native { npm.cmd pack "@gethopp/figma-mcp-bridge@$FigmaVersion" --pack-destination $work --silent } | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Couldn't download the bridge server from npm." }
    $tgz = @(Get-ChildItem $work -Filter '*.tgz')
    if ($tgz.Count -ne 1) { Fail "npm didn't produce the bridge server package." }
    $actual = (Get-FileHash -LiteralPath $tgz[0].FullName -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actual -ne $FigmaNpmSha512) {
      Fail "The bridge server download doesn't match its pinned checksum." @('Nothing was installed. Tell an admin.')
    }

    $zip = Join-Path $work 'plugin.zip'
    $url = "https://github.com/gethopp/figma-mcp-bridge/releases/download/v$FigmaVersion/figma-mcp-bridge-v$FigmaVersion.zip"
    Note "Downloading $url"
    Get-WithRetry $url $zip 'the Figma plugin'
    if ((Get-Sha256 $zip) -ne $FigmaPluginSha256) {
      Fail "The Figma plugin download doesn't match its pinned checksum." @('Nothing was installed. Tell an admin.')
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
    Note "Installed Figma MCP Bridge $FigmaVersion."
  }

  # Throws (with "Setup stopped:") on a problem; the caller turns that into a warning.
  function Install-FigmaBridge {
    if (-not (Has 'winget')) { Fail 'winget is needed for this step.' @('Install "App Installer" from the Microsoft Store.') }

    # Node.js runs the bridge server (it needs 20 or later).
    if ((Get-NodeMajor) -ge 20) {
      Note "Node.js $("$(Invoke-Native { node --version })".Trim()) is installed."
    } else {
      Say 'Installing Node.js LTS'
      if ($Dry) {
        Note '[dry run] would install Node.js LTS with winget'
      } else {
        Invoke-Native { winget install --id OpenJS.NodeJS.LTS --exact --source winget --silent --accept-package-agreements --accept-source-agreements }
        if ($LASTEXITCODE -ne 0) { Fail 'Installing Node.js LTS with winget failed.' }
        Update-SessionPath
        if ((Get-NodeMajor) -lt 20) {
          Fail 'Node.js 20 or later is needed, but "node --version" still shows an older one (or none).' @('Remove the old Node.js (or switch with your version manager) and run this again.')
        }
      }
    }

    # The plugin runs only in the Figma desktop app, not in the browser.
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe')) {
      Note 'The Figma desktop app is installed.'
    } else {
      Say 'Installing the Figma desktop app'
      if ($Dry) {
        Note '[dry run] would install the Figma desktop app with winget'
      } else {
        Invoke-Native { winget install --id Figma.Figma --exact --source winget --silent --accept-package-agreements --accept-source-agreements }
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
      if ($Dry) { Note "[dry run] would download and install Figma MCP Bridge into $FigmaDir" } else { Install-FigmaFiles }
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

  # ------------------------------------------------------------ run

  Start-Log
  $code = 0
  try {
    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Windows 10 or later is needed.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Update-SessionPath
    # A run that was killed can't reach its "finally"; clear what earlier runs left.
    Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'tb-gita-*' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $S.Tmp = Join-Path ([IO.Path]::GetTempPath()) ('tb-gita-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $S.Tmp | Out-Null

    $gita = Use-Gita
    Set-GitaFirstInUserPath
    Find-OtherGita
    Update-SessionPath
    $file = Get-OnboardingFile
    Invoke-Onboard $gita $file
    $code = $S.Code
    if ($code -ne 0) { Note "Gita stopped with exit code $code (see above)." }

    # ---- Optional: Figma for frontend work (after a finished onboarding) ----
    if ($code -eq 0 -and (Want-Figma)) {
      Write-Host ''
      Say 'Setting up Figma for frontend work'
      try {
        Install-FigmaBridge
        if (-not $Dry) {
          Record 'Figma, once: open the Figma desktop app, then Plugins > Development >'
          Record '  Import plugin from manifest... and pick:'
          Record "    $(Join-Path $FigmaDir 'plugin\manifest.json')"
          Record '  Then open the shared Figma file, run "Figma MCP Bridge" from'
          Record '  Plugins > Development, and start (or restart) claude.'
        }
      } catch {
        # Optional step: say what went wrong; the rest of the setup is done.
        Warn "The Figma step didn't finish: $($_.Exception.Message -replace '^Setup stopped: ', '')"
        Warn 'Everything else is set up. Fix that and run the setup again with TB_FIGMA=1.'
      }
    }
  } catch {
    $code = 1
    Write-Host ''
    $msg = $_.Exception.Message
    if ($msg -notlike 'Setup stopped:*') { $msg = "Setup stopped: $msg" }   # an unexpected error
    Write-Host $msg -ForegroundColor Red
    Note 'Fix the problem above and run the same command again.'
  } finally {
    if ($S.Tmp) { Remove-Item -LiteralPath $S.Tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($code -ne 0) {
    # No "exit" here: under "irm | iex" it would close the developer's terminal.
    # The script-level code below exits only when this runs as a .ps1 file.
    $global:LASTEXITCODE = $code
    $script:TbSetupExit = $code
  }
  if ($S.Notes.Count -gt 0) {
    Say 'From the setup script'
    foreach ($n in $S.Notes) { Note $n }
  }
  if ($S.Log) {
    Note "Log of this run: $($S.Log) (send it when asking for help)."
    try { Stop-Transcript | Out-Null } catch { }
  }
}

$script:TbSetupExit = 0
Install-ThoughtBoxDevSetup
# "powershell -File install.ps1" reports only an explicit exit code, so a failed run must
# exit with it there. Under "irm | iex" there is no script path and no exit (see above).
if ($script:TbSetupExit -ne 0 -and $MyInvocation.MyCommand.Path) { exit $script:TbSetupExit }
