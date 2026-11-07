# ThoughtBox developer setup for Windows.
#
#   irm https://raw.githubusercontent.com/ThoughtBoxFinTechAI/dev-setup/main/install.ps1 | iex
#
# Installs Git, GitHub CLI, Claude Code and Gita, cleans up old GitHub sign-ins,
# sets up your two GitHub accounts (@thoughtbox.io and @thoughtbox.one), clones
# claude-standards and runs its setup. Safe to run again: every step checks what
# is already there first, and repairs or reinstalls what is broken.
#
# Optional environment variables (set them before running, e.g. $env:TB_DRY_RUN = '1'):
#   TB_NAME, TB_EMAIL_IO, TB_EMAIL_ONE  answers to the questions, to skip them
#   TB_DRY_RUN=1        print what would change, change nothing
#   TB_CLEAN=1          remove old GitHub sign-ins and settings without asking
#   TB_LOG=<path>       write the log here instead of ~\.thoughtbox-setup.log
#   TB_GITA_ZIP=<path>  install Gita from a local zip (testing, no checksum)
#   TB_SKIP_SIGNIN=1    don't sign in to GitHub (testing)
#   TB_SKIP_STANDARDS=1 skip claude-standards and the Claude Code setup (testing)

# Everything is inside a function, so a half-downloaded script runs nothing.
function Install-ThoughtBoxDevSetup {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2

  # ---- Pinned versions. Update with every Gita release (see README). ----
  $GitaRepo    = 'naseebnaushad/gita'
  $GitaVersion = '1.0.2'
  $GitaAsset   = 'gita-windows-x64.zip'
  $GitaSha256  = 'd73ba7b9a1e34498e32432b6e73eb3d9007bb1cab1b51cc292a351b0d7d4334d'   # SHA-256 of $GitaAsset for $GitaVersion

  $StandardsUrl = 'https://github.com/ThoughtBoxFinTechAI/claude-standards.git'
  $StandardsDir = Join-Path $HOME 'claude-standards'
  $GitaHome     = Join-Path $HOME '.gita'
  $GitaCli      = Join-Path $GitaHome 'bin\gita.exe'
  $GitaAppDir   = Join-Path $env:LOCALAPPDATA 'Programs\Gita'
  $LabelIo      = 'ThoughtBox'
  $LabelOne     = 'ThoughtBox AI'
  $Dry          = $env:TB_DRY_RUN -eq '1'

  # Questions need a real console; without one, defaults are used.
  $Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' })

  # Shared state (an object, so the helper functions below can change it).
  $S = @{ Summary = New-Object System.Collections.ArrayList; Step = ''; Log = ''; GhLoggedOut = $false; Ids = @{} }

  # ------------------------------------------------------------ output

  function Say([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
  function Note([string]$Text) { Write-Host "    $Text" }
  function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }
  # Fail "what went wrong" "what to do"...: stops the setup.
  function Fail([string]$Text, [string[]]$Hints = @()) {
    $msg = "Setup stopped: $Text"
    foreach ($h in $Hints) { $msg += "`n    $h" }
    throw $msg
  }
  function Step([string]$Name) { $S.Step = $Name }
  function Ok([string]$Result) {
    if ($Dry -and $Result -notlike '*dry run*') { $Result = "$Result (dry run)" }
    [void]$S.Summary.Add(@($S.Step, $Result)); $S.Step = ''
  }
  function Record([string]$Name, [string]$Result) { [void]$S.Summary.Add(@($Name, $Result)) }
  function Needs-Attention {
    foreach ($r in $S.Summary) { if ($r[1] -match "failed|problem|couldn't") { return $true } }
    return $false
  }
  function Show-Summary {
    if ($S.Summary.Count -eq 0) { return }
    Write-Host ''
    Say 'Summary'
    foreach ($r in $S.Summary) { Note ('{0,-36} {1}' -f $r[0], $r[1]) }
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

  # ------------------------------------------------------------ input

  function Ask([string]$Prompt, [string]$Default, [string]$Preset) {
    if ($Preset) { return $Preset.Trim() }
    if (-not $Interactive) {
      $shown = if ($Default) { $Default } else { '(none)' }
      Note "${Prompt}: $shown (no terminal to ask)"; return $Default
    }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if (-not $answer) { $answer = $Default }
    return "$answer".Trim()
  }

  function Ask-Email([string]$Prompt, [string]$Domain, [string]$Preset) {
    while ($true) {
      $email = "$(Ask $Prompt '' $Preset)".ToLowerInvariant() -replace '\s', ''
      if ($email -match "^[^@\s]+@$([regex]::Escape($Domain))$") { return $email }
      if ($Preset) { Fail "$email is not an @$Domain address." }
      if (-not $Interactive) { Fail "No terminal to ask for your @$Domain email." @('Set TB_EMAIL_IO and TB_EMAIL_ONE.') }
      Warn "Please enter your @$Domain address."
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

  # ------------------------------------------------------------ commands

  # Runs a native command with its output shown (and logged); returns the exit code.
  # PowerShell 5.1 turns a native program's error output into errors, so the
  # error preference is relaxed while it runs.
  function Native([scriptblock]$Do) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      & $Do 2>&1 | ForEach-Object { Write-Host "$_" }
      return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
  }

  # Runs a native command quietly; returns @{ Code; Out }.
  function Capture([scriptblock]$Do) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $out = & $Do 2>&1 | ForEach-Object { "$_" }
      return @{ Code = $LASTEXITCODE; Out = (@($out) -join "`n") }
    } catch {
      return @{ Code = 9009; Out = $_.Exception.Message }
    } finally { $ErrorActionPreference = $old }
  }

  function Has([string]$Cmd) { [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

  # Installed AND runs.
  function Works([string]$Cmd) {
    if (-not (Has $Cmd)) { return $false }
    $r = Capture { & $Cmd --version }
    return $r.Code -eq 0
  }

  # Picks up PATH changes made by installers, without a new terminal. Keeps
  # this session's own entries first and adds the new ones after them.
  function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $all = New-Object System.Collections.ArrayList
    foreach ($p in (@($env:Path, $machine, $user, (Join-Path $GitaHome 'bin'), (Join-Path $HOME '.local\bin')) -join ';') -split ';') {
      if ($p -and -not ($all -contains $p)) { [void]$all.Add($p) }
    }
    $env:Path = $all -join ';'
  }

  function Add-UserPath([string]$Dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -contains $Dir) { return }
    if ($Dry) { Note "[dry run] would add $Dir to your PATH"; return }
    [Environment]::SetEnvironmentVariable('Path', (($parts + $Dir) -join ';'), 'User')
  }

  # A free "<path>.backup-<date-time>" name; never overwrites an earlier backup.
  function Backup-Name([string]$Path) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $b = "$Path.backup-$stamp"; $n = 2
    while (Test-Path -LiteralPath $b) { $b = "$Path.backup-$stamp-$n"; $n++ }
    return $b
  }

  # ------------------------------------------------------------ prerequisites

  function Ensure-WingetTool([string]$Cmd, [string]$Id, [string]$Name, [bool]$Optional) {
    if (Works $Cmd) { Note "$Name is installed."; return 'already installed' }
    $force = @()
    if (Has $Cmd) { Warn "$Name is installed but doesn't run. Reinstalling it."; $force = @('--force') }
    if (-not (Has 'winget')) {
      $msg = "$Name is missing and winget isn't available."
      $fix = 'Install "App Installer" from the Microsoft Store, then run this again.'
      if ($Optional) { Warn "$msg $fix"; return 'not installed (optional)' }
      Fail $msg @($fix)
    }
    Say "Installing $Name"
    if ($Dry) { Note "[dry run] would install $Name with winget"; return 'dry run' }
    $code = Native { winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements @force }
    Update-SessionPath
    if (Works $Cmd) { return 'installed' }
    $msg = "Installing $Name failed (winget exit $code)."
    if ($Optional) { Warn "$msg Get it from https://cli.github.com if you need it."; return 'not installed (optional)' }
    Fail $msg @('The messages above say why. Install it yourself, open a new terminal and run this again.')
  }

  function Ensure-Claude {
    if (Works 'claude') { Note 'Claude Code is installed.'; return 'already installed' }
    if (Has 'claude') { Warn "Claude Code is installed but doesn't run. Reinstalling it." }
    Say 'Installing Claude Code'
    if ($Dry) { Note '[dry run] would install Claude Code (official installer from claude.ai)'; return 'dry run' }
    try {
      $installer = Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -TimeoutSec 60 -UseBasicParsing
      Invoke-Expression $installer
    } catch {
      Fail "Installing Claude Code failed: $($_.Exception.Message)" @('Check your internet connection, then run this again.')
    }
    Update-SessionPath
    if (-not (Works 'claude')) {
      Fail "Claude Code was installed but doesn't run." @('Open a new terminal and run "claude --version". If it still fails, see https://docs.claude.com/en/docs/claude-code/setup.')
    }
    return 'installed'
  }

  # ------------------------------------------------------------ Gita

  # missing | ok | old:<version> | broken:<exit code>
  function Get-GitaState {
    if (-not (Test-Path -LiteralPath $GitaCli)) { return 'missing' }
    $r = Capture { & $GitaCli --version }
    if ($r.Code -ne 0) { return "broken:$($r.Code)" }
    $v = $r.Out.Trim()
    if ($v -eq "gita $GitaVersion") { return 'ok' }
    return "old:$($v -replace '^gita ', '')"
  }

  function Broken-Reason([string]$Code) {
    switch ($Code) {
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

  function Get-WithRetry([string]$Url, [string]$OutFile) {
    $ProgressPreference = 'SilentlyContinue'
    for ($i = 1; $i -le 3; $i++) {
      try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300; return }
      catch {
        if ($i -eq 3) {
          Fail "Couldn't download Gita: $($_.Exception.Message)" @('Check your internet connection and that github.com opens in your browser, then run this again.')
        }
        Start-Sleep -Seconds 3
      }
    }
  }

  function Install-Gita {
    # A run that was killed can't reach its "finally"; clear what earlier runs left.
    Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'tb-gita-*' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $work = Join-Path ([IO.Path]::GetTempPath()) ('tb-gita-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
      $zip = Join-Path $work $GitaAsset
      if ($env:TB_GITA_ZIP) {
        Warn "Using the local file $env:TB_GITA_ZIP (no checksum check)."
        Copy-Item -LiteralPath $env:TB_GITA_ZIP $zip
      } else {
        if (-not $GitaSha256) { Fail "Gita $GitaVersion has no pinned checksum in this script yet." @('Ask an admin.') }
        $url = "https://github.com/$GitaRepo/releases/download/v$GitaVersion/$GitaAsset"
        Note "Downloading $url"
        Get-WithRetry $url $zip
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($actual -ne $GitaSha256.ToUpperInvariant()) {
          Fail "The Gita download doesn't match its pinned checksum (got $actual)." @('Nothing was installed. Tell an admin.')
        }
        Note 'Checksum OK.'
      }
      $unpacked = Join-Path $work 'app'
      try { Expand-Archive -Path $zip -DestinationPath $unpacked }
      catch { Fail "Couldn't unpack the Gita download: $($_.Exception.Message)" @('Run this again; if it repeats, tell an admin.') }
      if (-not (Test-Path (Join-Path $unpacked 'cli\bin\gita.exe'))) { Fail 'The Gita download has no cli\bin\gita.exe.' @('Tell an admin.') }

      Close-Gita
      try {
        if (Test-Path -LiteralPath $GitaAppDir) { Remove-Item -LiteralPath $GitaAppDir -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path $GitaAppDir) -Force | Out-Null
        Move-Item -LiteralPath $unpacked $GitaAppDir

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
        $programs = [Environment]::GetFolderPath('Programs')
        if ($programs) {
          $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'Gita.lnk'))
          $lnk.TargetPath = Join-Path $GitaAppDir 'gita.exe'
          $lnk.WorkingDirectory = $GitaAppDir
          $lnk.Save()
        }
      } catch { Warn "Couldn't add Gita to the Start menu: $($_.Exception.Message)" }
    } finally {
      Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Ensure-Gita {
    $st = Get-GitaState
    if ($st -eq 'ok' -and -not $env:TB_GITA_ZIP) { Note "Gita $GitaVersion is installed and runs."; return 'already installed' }
    if ($st -like 'old:*') { Note "Gita $($st.Substring(4)) is installed. Updating to $GitaVersion." }
    if ($st -like 'broken:*') { Warn "Gita is installed but doesn't run: $(Broken-Reason $st.Substring(7)). Reinstalling it." }
    Say "Installing Gita $GitaVersion"
    if ($Dry) { Note "[dry run] would download Gita into $GitaAppDir and replace $GitaHome\bin and $GitaHome\lib"; return 'dry run' }
    Install-Gita
    $st = Get-GitaState
    if ($st -eq 'ok') { Note "Installed gita $GitaVersion and checked that it runs."; return "installed $GitaVersion" }
    if ($st -like 'broken:*') {
      Fail "Gita was installed but doesn't run: $(Broken-Reason $st.Substring(7))." @("Run `"$GitaCli --version`" to see the error, and send it with the log to an admin.")
    }
    if ($st -like 'old:*') { Fail "Gita was installed but reports version $($st.Substring(4)) instead of $GitaVersion." @('Tell an admin.') }
    Fail "Gita was installed but $GitaCli is missing." @('Tell an admin.')
  }

  # ------------------------------------------------------------ clean-up

  # Hides a token that may sit in an address (https://user:token@github.com).
  function Redact([string]$Text) { return ($Text -replace '//[^/@ ]+@', '//***@') }

  # Runs git outside any repository, so no repository's settings (or Gita's
  # per-folder rules) take part.
  function Git-Outside([scriptblock]$Do) {
    Push-Location -LiteralPath ([IO.Path]::GetPathRoot($env:SystemRoot))
    try { return (Capture $Do) } finally { Pop-Location }
  }

  # Runs "git credential <action>" for github.com outside any repository and
  # returns its exit code. The request comes from a file through cmd, because
  # Windows PowerShell and .NET put a byte-order mark in front of text sent to
  # a program when the console uses UTF-8, and git then rejects the request.
  # Git's answer (which may hold a password) goes to NUL, never to the screen
  # or the log. Askpass points nowhere so no window or prompt can appear.
  function Git-Credential([string]$Action) {
    $req = [IO.Path]::GetTempFileName()
    try {
      [IO.File]::WriteAllBytes($req, [Text.Encoding]::ASCII.GetBytes("protocol=https`nhost=github.com`n`n"))
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
      $psi.Arguments = "/d /s /c `"git -c core.askPass=tb-no-askpass credential $Action <`"$req`" >NUL 2>NUL`""
      $psi.WorkingDirectory = [IO.Path]::GetPathRoot($env:SystemRoot)
      $psi.UseShellExecute = $false
      $psi.EnvironmentVariables['GIT_ASKPASS'] = 'tb-no-askpass'
      $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
      $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
      $p = [System.Diagnostics.Process]::Start($psi)
      if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; return 124 }
      return $p.ExitCode
    } catch { return 9009 }
    finally { Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue }
  }

  # True if a configured helper holds a github.com login.
  function Has-SavedLogin { return (Git-Credential 'fill') -eq 0 }

  # Finds old GitHub sign-ins and settings that can make git or gh use another
  # account. Items: @{ Text; Kind; Arg }. Reads ~/.gitconfig itself, never the
  # files Gita includes.
  function Find-Cleanup {
    $items = New-Object System.Collections.ArrayList
    $report = New-Object System.Collections.ArrayList
    $add = { param($t, $k, $a)
      foreach ($i in $items) { if ($i.Kind -eq $k -and $i.Arg -eq $a) { return } }
      [void]$items.Add(@{ Text = $t; Kind = $k; Arg = $a })
    }

    # Saved github.com logins: erased first, while every helper is still configured.
    $helpers = @((Git-Outside { git config --get-all credential.helper }).Out -split "`n" |
        Where-Object { $_ -and $_ -notmatch 'gh auth|gita' } | Sort-Object -Unique)
    if ($helpers.Count -gt 0 -and (Has-SavedLogin)) {
      $h = $helpers -join ', '
      if ($h -match 'password|token') { $h = '(a custom helper)' }
      & $add "Saved github.com logins in: $h (erased with `"git credential reject`")" 'reject' ''
    }
    # Git Credential Manager keeps one entry per account; a reject only reaches the default one.
    # Matched on the entry name, not cmdkey's labels, which are translated on non-English Windows.
    $cmd = Capture { cmdkey /list }
    $seen = @{}
    foreach ($line in ($cmd.Out -split "`n")) {
      if ($line -match '(git:https://([^@/\s]+@)?github\.com(/\S*)?)\s*$' -and -not $seen[$Matches[1]]) {
        $seen[$Matches[1]] = $true
        & $add "Windows Credential Manager entry $($Matches[1])" 'cmdkey' $Matches[1]
      }
    }

    foreach ($line in ((Capture { git config --global --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' }).Out -split "`n")) {
      if (-not $line -or $line -notmatch 'github\.com') { continue }
      $k, $v = $line -split ' ', 2
      & $add "git setting $(Redact $k) = $(Redact $v) (sends github.com addresses somewhere else, e.g. SSH)" 'unset' $k
    }
    foreach ($k in ((Capture { git config --global --name-only --get-regexp '^http\..*github\.com.*\.extraheader$' }).Out -split "`n")) {
      if ($k) { & $add "git setting $(Redact $k) (sends a fixed sign-in with every github.com request)" 'unset' $k }
    }
    if ((Capture { git config --global --get-all http.extraheader }).Out -match '(?im)^authorization') {
      & $add 'git setting http.extraheader (a sign-in header sent to every site, github.com included)' 'unset' 'http.extraheader'
    }
    foreach ($line in ((Capture { git config --global --get-regexp '^credential\..*github\.com.*\.helper$' }).Out -split "`n")) {
      if (-not $line) { continue }
      $k, $v = $line -split ' ', 2
      if ($v -match 'password|token|=') { $v = '(a custom command)' }
      & $add "git setting $(Redact $k) = $v (an old github.com login helper)" 'unset' $k
    }

    if (Has 'gh') {
      $saved = @{ GH_TOKEN = $env:GH_TOKEN; GITHUB_TOKEN = $env:GITHUB_TOKEN }
      $env:GH_TOKEN = $null; $env:GITHUB_TOKEN = $null
      try { $st = Capture { gh auth status --hostname github.com } }
      finally { $env:GH_TOKEN = $saved.GH_TOKEN; $env:GITHUB_TOKEN = $saved.GITHUB_TOKEN }
      foreach ($m in [regex]::Matches($st.Out, 'Logged in to github\.com (?:account|as) ([A-Za-z0-9-]+)')) {
        & $add "GitHub CLI login @$($m.Groups[1].Value) (gh auth logout)" 'ghlogout' $m.Groups[1].Value
      }
    }

    foreach ($var in 'GH_TOKEN', 'GITHUB_TOKEN') {
      if ([Environment]::GetEnvironmentVariable($var, 'User')) {
        & $add "Your Windows environment variable $var (gh and other tools use it instead of your sign-in)" 'userenv' $var
      }
      if ([Environment]::GetEnvironmentVariable($var, 'Machine')) {
        [void]$report.Add("$var is set for all users of this computer. gh and other tools use it instead of your sign-in. Ask an admin to remove it.")
      }
    }
    $ssh = Join-Path $HOME '.ssh\config'
    if ((Test-Path -LiteralPath $ssh) -and (Select-String -LiteralPath $ssh -Pattern '^\s*host\s.*github\.com' -Quiet)) {
      [void]$report.Add('~\.ssh\config has a "Host github.com" entry. It only matters for SSH addresses (git@github.com:...) and was not changed.')
    }
    return @{ Items = $items; Report = $report }
  }

  function Invoke-Cleanup {
    Say 'Looking for old GitHub sign-ins and settings'
    $found = Find-Cleanup
    foreach ($r in $found.Report) { Warn $r }
    # This run never uses a token from the environment.
    $env:GH_TOKEN = $null; $env:GITHUB_TOKEN = $null
    $items = $found.Items
    if ($items.Count -eq 0) { Note 'None found.'; return 'nothing to clean' }
    Note 'Found these. They can make git or gh use an old GitHub account instead of your Gita sign-in:'
    foreach ($i in $items) { Note "  - $($i.Text)" }
    if ($Dry) { Note '[dry run] would ask, back up ~\.gitconfig and remove the items above'; return 'dry run' }
    if ($env:TB_CLEAN -ne '1') {
      if (-not $Interactive) {
        Warn 'No terminal to ask, so nothing was removed. Set TB_CLEAN=1 to remove them.'
        return 'kept (no terminal)'
      }
      if (-not (Ask-YN "Remove them? ~\.gitconfig is backed up first. Gita's own sign-ins, other sites and SSH keys are not touched." $true)) {
        Warn "Kept. If cloning later says a project doesn't exist, run this again and answer yes."
        return 'kept (your choice)'
      }
    }

    $gitconfig = Join-Path $HOME '.gitconfig'
    if (Test-Path -LiteralPath $gitconfig) {
      $backup = Backup-Name $gitconfig
      try { Copy-Item -LiteralPath $gitconfig $backup } catch { Fail "Couldn't back up ~\.gitconfig, so nothing was removed." }
      Note "Backed up ~\.gitconfig to $backup."
    }

    $n = 0
    foreach ($i in $items) {
      switch ($i.Kind) {
        'reject' {
          $okAll = $true
          for ($t = 0; $t -lt 3; $t++) {
            if ((Git-Credential 'reject') -ne 0) { $okAll = $false }
          }
          if ($okAll) { $n++ } else { Warn "Couldn't erase the saved github.com logins." }
        }
        'cmdkey' {
          $r = Capture { cmdkey "/delete:LegacyGeneric:target=$($i.Arg)" }
          if ($r.Code -ne 0) { $r = Capture { cmdkey "/delete:$($i.Arg)" } }
          # Already gone (erased by the reject above) counts as done.
          if ($r.Code -eq 0 -or -not ((Capture { cmdkey /list }).Out -match ([regex]::Escape($i.Arg) + '\s*(\r?\n|$)'))) { $n++ }
          else { Warn "Couldn't remove the Credential Manager entry $($i.Arg)." }
        }
        'unset' {
          $r = Capture { git config --global --unset-all $i.Arg }
          if ($r.Code -eq 0) { $n++ } else { Warn "Couldn't remove the git setting $(Redact $i.Arg)." }
        }
        'ghlogout' {
          $r = Capture { gh auth logout --hostname github.com --user $i.Arg }
          if ($r.Code -eq 0) { $n++; $S.GhLoggedOut = $true }
          else { Warn "Couldn't sign GitHub CLI out of @$($i.Arg). Run `"gh auth logout`" yourself." }
        }
        'userenv' {
          [Environment]::SetEnvironmentVariable($i.Arg, $null, 'User'); $n++
        }
      }
    }
    Note "Removed $n of $($items.Count)."
    if ($n -eq $items.Count) { return "cleaned ($n)" }
    return "cleaned $n of $($items.Count) (some failed)"
  }

  # ------------------------------------------------------------ profiles and sign-in

  function Get-Profiles {
    if (-not (Test-Path -LiteralPath $GitaCli)) { return @() }
    $r = Capture { & $GitaCli profiles --json }
    if ($r.Code -ne 0) {
      Fail "Gita couldn't list its profiles (exit $($r.Code))." @("Run `"$GitaCli profiles`" to see the error. If Gita doesn't run, run this setup again to reinstall it.")
    }
    return @(($r.Out | ConvertFrom-Json).profiles)
  }

  function Get-Profile([string]$Id) {
    $p = @(Get-Profiles | Where-Object { $_.id -eq $Id })
    if ($p.Count -gt 0) { return $p[0] }
    return $null
  }

  function Login-Of($Profile) {
    if ($Profile -and $Profile.githubLogin) { return [string]$Profile.githubLogin }
    return ''
  }

  # Returns the id of the profile for this email, adding one if needed.
  function Ensure-Profile([string]$Name, [string]$Email, [string]$Label) {
    $found = @(Get-Profiles | Where-Object { $_.email -eq $Email })
    if ($found.Count -gt 0) {
      Note "Profile for $Email already exists (`"$($found[0].label)`")."
      return $found[0].id
    }
    if ($Dry) { Note "[dry run] would add the Gita profile `"$Label`" for $Email"; return "<$Label>" }
    $r = Capture { & $GitaCli profile add --name $Name --email $Email --label $Label --json }
    if ($r.Code -ne 0) { Fail "Couldn't add the Gita profile for $Email (exit $($r.Code))." @($r.Out) }
    $id = ($r.Out | ConvertFrom-Json).profile.id
    if (-not $id) { Fail "Gita added the profile for $Email but didn't say its id." @('Run "gita profiles" and tell an admin.') }
    Note "Added the Gita profile `"$Label`" for $Email."
    return $id
  }

  function Show-Profiles {
    foreach ($p in Get-Profiles) {
      if ($p.signedIn) { Note "$($p.email): signed in to GitHub as @$(if ($p.githubLogin) { $p.githubLogin } else { 'unknown' })" }
      else { Note "$($p.email): not signed in to GitHub yet" }
    }
  }

  # Signs in and confirms the account, with one retry.
  function SignIn-Flow([string]$Id, [string]$Email, [string]$Label, [string]$Other) {
    for ($try = 1; $try -le 2; $try++) {
      Say "Sign in to GitHub with the account for $Email"
      Note "A code is shown below. Enter it on github.com while signed in as your $Email GitHub account."
      Note 'GitHub signs in whoever is logged in to github.com in your browser. If that is your other account, sign out there first (or use a private window).'
      if ($Dry) { Note "[dry run] would sign in `"$Label`" to GitHub"; return }
      $code = Native { & $GitaCli sign-in --profile $Id }
      if ($code -ne 0) {
        Fail "Signing in $Email to GitHub failed." @('Run this again. If it keeps failing, check that github.com opens in your browser.')
      }
      $login = Login-Of (Get-Profile $Id); $otherLogin = Login-Of (Get-Profile $Other)
      if ($login -and $login -eq $otherLogin) {
        Warn "That is @$login, the account your other profile already uses."
      } else {
        $shown = if ($login) { $login } else { 'unknown' }
        if (Ask-YN "Signed in as @$shown. Is that your GitHub account for ${Email}?" $true) { return }
      }
      if ($try -eq 1) {
        Warn "Let's sign in again. First sign out of github.com in your browser (or open a private window), then sign in as your $Email account."
      }
    }
    Fail "`"$Label`" is still not signed in with your $Email GitHub account." @(
      "In your browser, sign out of github.com and sign in as your $Email account. Then run:",
      "  gita sign-in --profile `"$Label`"",
      'and run this setup again.')
  }

  # An existing sign-in is kept only if it is the right account: the developer
  # confirms the login, and it must differ from the other profile's login.
  function Ensure-SignIn([string]$Id, [string]$Email, [string]$Label, [string]$Other) {
    if ($env:TB_SKIP_SIGNIN -eq '1') { Warn "Skipping GitHub sign-in for $Email."; return 'skipped (TB_SKIP_SIGNIN)' }
    $p = Get-Profile $Id; $o = Get-Profile $Other
    $login = Login-Of $p; $otherLogin = Login-Of $o
    if ($p -and $p.signedIn) {
      $shown = if ($login) { $login } else { 'unknown' }
      if ($login -and $login -eq $otherLogin -and $o.signedIn) {
        Warn "Both of your Gita profiles are signed in as @$login. One GitHub account can't be both your @thoughtbox.io and @thoughtbox.one account, so `"$Label`" is signed in again."
      } elseif (Ask-YN "`"$Label`" is signed in to GitHub as @$shown. Is that your GitHub account for ${Email}?" $true) {
        Note 'Keeping that sign-in.'; return "already signed in as @$shown"
      }
    }
    SignIn-Flow $Id $Email $Label $Other
    if ($Dry) { return 'dry run' }
    return "signed in as @$(Login-Of (Get-Profile $Id))"
  }

  # ------------------------------------------------------------ claude-standards

  function Norm-Url([string]$Url) {
    $u = $Url.ToLowerInvariant() -replace '^(https?|ssh|git)://', '' -replace '^[^@/]+@', '' -replace '^github\.com:', 'github.com/'
    return ($u -replace '/+$', '' -replace '\.git$', '')
  }

  # clean | dirty | move:<reason>
  function Get-StandardsState {
    $d = $StandardsDir
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { return 'move:not a folder' }
    if (-not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) { return 'move:empty' }
    if (-not (Test-Path -LiteralPath (Join-Path $d '.git'))) { return 'move:not a git copy' }
    $url = (Capture { git -C $d config --get remote.origin.url }).Out.Trim()
    if ((Norm-Url $url) -ne (Norm-Url $StandardsUrl)) { return 'move:a copy of a different project' }
    $st = Capture { git -C $d status --porcelain }
    if ($st.Code -ne 0) { return 'move:a damaged git copy' }
    if ($st.Out.Trim()) { return 'dirty' }
    return 'clean'
  }

  function Ensure-Standards([hashtable]$Ctx) {
    $d = $StandardsDir
    if (Test-Path -LiteralPath $d) {
      $st = Get-StandardsState
      if ($st -eq 'clean') {
        Say 'Updating claude-standards'
        if ($Dry) { Note "[dry run] would update $d (git pull --ff-only)"; return 'dry run' }
        # BatchMode: an SSH address must fail, not stop at a host-key or passphrase prompt.
        $oldSsh = $env:GIT_SSH_COMMAND; $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=15'
        try { $code = Native { git -C $d -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -c advice.diverging=false pull --ff-only -q } }
        finally { $env:GIT_SSH_COMMAND = $oldSsh }
        if ($code -eq 0) { Note 'claude-standards is up to date.'; return 'updated' }
        Warn "Couldn't update claude-standards (the message above says why). Using the copy you have."
        return 'kept (update failed)'
      }
      if ($st -eq 'dirty') {
        Warn "claude-standards in $d has local changes, so it was not updated."
        return 'kept (local changes)'
      }
      # Never deleted: moved aside with a timestamp.
      $backup = Backup-Name $d
      Warn "$d is $($st.Substring(5)). Moving it to $backup and downloading a fresh copy."
      if ($Dry) { Note "[dry run] would move $d to $backup" }
      else {
        try { Move-Item -LiteralPath $d $backup }
        catch { Fail "Couldn't move $d to ${backup}: $($_.Exception.Message)" @('Close any program using that folder, then run this again.') }
      }
    }
    return (Clone-Standards $Ctx)
  }

  function Clone-Standards([hashtable]$Ctx) {
    Say 'Downloading claude-standards'
    if ($Dry) { Note "[dry run] would clone claude-standards into $StandardsDir"; return 'dry run' }
    for ($try = 1; $try -le 2; $try++) {
      $code = Native { & $GitaCli clone $StandardsUrl $StandardsDir --profile $Ctx.IdOne }
      if ($code -eq 0) { return 'downloaded' }
      # The folder did not exist before this clone, so anything left is a partial copy.
      if (Test-Path -LiteralPath $StandardsDir) { Remove-Item -LiteralPath $StandardsDir -Recurse -Force -ErrorAction SilentlyContinue }
      $login = Login-Of (Get-Profile $Ctx.IdOne)
      if (-not $login) { $login = 'unknown' }
      Warn "Couldn't download claude-standards. Likely causes:"
      Note "  1. ThoughtBoxFinTechAI hasn't approved the Gita app yet (the most common cause). On"
      Note '     github.com open Settings > Applications > Authorized OAuth Apps > Gita, click'
      Note '     "Request" next to ThoughtBoxFinTechAI, and ask an org owner to approve it under'
      Note '     Organization settings > Third-party access.'
      Note "  2. `"$LabelOne`" is signed in as @$login. It must be your $($Ctx.EmailOne) GitHub account,"
      Note '     the one that is a member of ThoughtBoxFinTechAI.'
      Note "  3. Your account hasn't been added to ThoughtBoxFinTechAI yet. Ask an admin."
      Note '  4. No connection to github.com.'
      if ($try -ne 1 -or -not $Interactive -or $env:TB_SKIP_SIGNIN -eq '1') { break }
      if (-not (Ask-YN "Sign `"$LabelOne`" in to GitHub again and retry?" $true)) { break }
      SignIn-Flow $Ctx.IdOne $Ctx.EmailOne $LabelOne $Ctx.IdIo
    }
    Fail "claude-standards couldn't be downloaded." @('Check the causes listed above, then run this again.')
  }

  function Import-Company([string]$File, [string]$ProfileId) {
    if ($Dry) { Note "[dry run] would import gita/$File"; return }
    $f = Join-Path $StandardsDir "gita\$File"
    if (-not (Test-Path -LiteralPath $f)) {
      Fail "claude-standards has no gita/$File." @("It may be an old copy. Run `"git -C $StandardsDir pull`", then run this again.")
    }
    $code = Native { & $GitaCli company import $f --profile $ProfileId }
    if ($code -ne 0) { Fail "Gita couldn't import gita/$File (the message above says why)." @('Run this again; if it repeats, send the log to an admin.') }
  }

  function Connect-Claude {
    if ($Dry) { Note '[dry run] would connect Gita to Claude Code'; return 'dry run' }
    if (-not (Works 'claude')) {
      Warn 'Claude Code is not on PATH yet, so Gita was not connected to it. Open a new terminal and run "gita mcp add-to-claude".'
      return "couldn't connect (run gita mcp add-to-claude)"
    }
    $code = Native { & $GitaCli mcp add-to-claude }
    if ($code -eq 0) { return 'connected' }
    Warn "Couldn't connect Gita to Claude Code. Close Claude Code, then run `"gita mcp add-to-claude`"."
    return 'failed (run gita mcp add-to-claude)'
  }

  function Invoke-Doctor {
    Say 'Checking the setup'
    if ($Dry) { Note '[dry run] would run gita doctor'; return 'dry run' }
    $r = Capture { & $GitaCli doctor }
    Write-Host $r.Out
    switch ($r.Code) {
      # Exit 0 can still carry "Heads up" notes (not blocking).
      0 { if ($r.Out -match 'Heads up') { return 'ok, with notes (above)' } return 'all good' }
      1 {
        Warn 'Gita found problems (listed above). Run "gita doctor --fix", or follow the advice it printed.'
        return 'problems found (run gita doctor --fix)'
      }
      default { Warn "gita doctor couldn't run (exit $($r.Code))."; return "couldn't run (exit $($r.Code))" }
    }
  }

  # ------------------------------------------------------------ the steps

  function Invoke-Steps {
    Say 'Checking prerequisites'
    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Windows 10 or later is needed.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Never let git or Git Credential Manager stop to ask for a password: a
    # missing sign-in must fail with a message, not hang.
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    Update-SessionPath

    Step 'Git'; Ok (Ensure-WingetTool 'git' 'Git.Git' 'Git for Windows' $false)
    Step 'GitHub CLI'; Ok (Ensure-WingetTool 'gh' 'GitHub.cli' 'GitHub CLI' $true)
    Step 'Claude Code'; Ok (Ensure-Claude)

    Step 'Gita'; Ok (Ensure-Gita)
    Add-UserPath (Join-Path $GitaHome 'bin')
    Update-SessionPath

    Step 'Clean-up of old GitHub sign-ins'; Ok (Invoke-Cleanup)

    Say 'Your GitHub accounts'
    Step 'Gita profiles'
    $defaultName = "$((Capture { git config --global user.name }).Out)".Trim()
    $name = Ask 'Your full name (shown on commits)' $defaultName $env:TB_NAME
    if (-not $name) { Fail 'A name is needed.' }
    $emailIo = Ask-Email 'Your @thoughtbox.io email (projects in thoughtboxhub)' 'thoughtbox.io' $env:TB_EMAIL_IO
    $emailOne = Ask-Email 'Your @thoughtbox.one email (projects in ThoughtBoxFinTechAI)' 'thoughtbox.one' $env:TB_EMAIL_ONE
    $idIo = Ensure-Profile $name $emailIo $LabelIo
    $idOne = Ensure-Profile $name $emailOne $LabelOne
    Show-Profiles
    Ok 'ready'
    $ctx = @{ IdIo = $idIo; IdOne = $idOne; EmailOne = $emailOne }

    # The AI account first: claude-standards lives in its organization.
    Step "Sign-in $emailOne"; Ok (Ensure-SignIn $idOne $emailOne $LabelOne $idIo)

    if ($env:TB_SKIP_STANDARDS -eq '1') {
      Warn 'Skipping claude-standards.'
      Record 'claude-standards' 'skipped (TB_SKIP_STANDARDS)'
    } else {
      Step 'claude-standards'; Ok (Ensure-Standards $ctx)
      Step 'Company account rules'
      Say 'Telling Gita which organization uses which account'
      Import-Company 'thoughtbox.json' $idIo
      Import-Company 'thoughtbox-ai.json' $idOne
      Ok 'imported'
    }

    Step "Sign-in $emailIo"; Ok (Ensure-SignIn $idIo $emailIo $LabelIo $idOne)

    if ($env:TB_SKIP_STANDARDS -ne '1') {
      Step 'Claude Code company setup'
      Say 'Setting up Claude Code with the company standards'
      $setup = Join-Path $StandardsDir 'setup.ps1'
      if ($Dry) { Note '[dry run] would run the claude-standards setup' }
      else {
        if (-not (Test-Path -LiteralPath $setup)) {
          Fail "$StandardsDir has no setup.ps1." @('It may be an old or incomplete copy. Move the folder away and run this again.')
        }
        $code = Native { powershell -NoProfile -ExecutionPolicy Bypass -File $setup }
        if ($code -ne 0) { Fail 'The claude-standards setup failed (its messages are above).' @('Fix what it says, then run this again. Finished steps are skipped.') }
      }
      Ok 'done'
      Step 'Gita in Claude Code'; Ok (Connect-Claude)
    }

    Step 'Gita doctor'; Ok (Invoke-Doctor)
  }

  # ------------------------------------------------------------ run

  Start-Log
  $failed = $false
  try {
    Invoke-Steps
  } catch {
    $failed = $true
    if ($S.Step) { Record $S.Step 'failed' }
    Write-Host ''
    $msg = $_.Exception.Message
    if ($msg -notlike 'Setup stopped:*') { $msg = "Setup stopped: $msg" }   # an unexpected error
    Write-Host $msg -ForegroundColor Red
  }
  Show-Summary
  Write-Host ''
  if ($failed) {
    # No "exit" here: under "irm | iex" it would close the developer's terminal.
    # The script-level code below exits 1 only when this runs as a .ps1 file.
    $global:LASTEXITCODE = 1
    $script:TbSetupFailed = $true
    Note 'Fix the problem above and run the same command again. Finished steps are skipped.'
  } else {
    if ($Dry) { Say 'Dry run finished. Nothing was changed.' }
    elseif (Needs-Attention) { Say 'Finished, but some steps need attention (marked above).' }
    else { Say 'Done.' }
    Note 'Next:'
    Note '  1. Open a new terminal (so PATH changes apply).'
    Note '  2. Run "claude" and sign in with your company Claude Teams seat.'
    Note '  3. Clone projects with "gita clone <address>", so each uses the right account.'
    if ($S.GhLoggedOut) { Note '  4. GitHub CLI was signed out. If you use it, run "gh auth login" with the right account.' }
  }
  if ($S.Log) {
    Note "Log of this run: $($S.Log) (send it when asking for help)."
    try { Stop-Transcript | Out-Null } catch { }
  }
}

$script:TbSetupFailed = $false
Install-ThoughtBoxDevSetup
# "powershell -File install.ps1" reports only an explicit exit code, so a failed run must
# exit 1 there. Under "irm | iex" there is no script path and no exit (see above).
if ($script:TbSetupFailed -and $MyInvocation.MyCommand.Path) { exit 1 }
