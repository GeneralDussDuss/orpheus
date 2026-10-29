# Install Orpheus on Windows.
#
#   irm https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.ps1 | iex
#
# installs what is missing with winget (git, uv, mpv, cava, yt-dlp), fetches
# Orpheus into %LOCALAPPDATA%\Orpheus\app (or updates it), builds its Python
# environment, adds Orpheus to the Start menu and opens it. Safe to re-run;
# that is how you update. To remove it again:
#
#   & "$env:LOCALAPPDATA\Orpheus\app\install.ps1" -Uninstall
#
# which keeps your sign-in and settings in %LOCALAPPDATA%\Orpheus\state.
# Written for Windows PowerShell 5.1, which every Windows 10 and 11 has.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$Repo = if ($env:ORPHEUS_REPO) { $env:ORPHEUS_REPO } else { 'https://github.com/GeneralDussDuss/orpheus' }
$Home_ = Join-Path $env:LOCALAPPDATA 'Orpheus'
$App = Join-Path $Home_ 'app'
$Menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Orpheus.lnk'

function Ok($m)   { Write-Host "  + $m" -ForegroundColor Green }
function Note($m) { Write-Host "  * $m" -ForegroundColor Yellow }
function Step($m) { Write-Host "`n$m" -ForegroundColor White }
function Has($c)  { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# winget only reaches PATH in a new shell; read it back so this one sees the tools.
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Stop-Orpheus {
  # By command line, not path: a venv's pythonw.exe relaunches the base Python,
  # so the running processes do not live under the app folder. Then what they
  # started too, since mpv and cava keep the app folder as their working directory.
  $all = @(Get-CimInstance Win32_Process)
  $ids = @($all | Where-Object { $_.CommandLine -match 'orpheusd' } | ForEach-Object { $_.ProcessId })
  $kids = @($all | Where-Object { $ids -contains $_.ParentProcessId } | ForEach-Object { $_.ProcessId })
  $grand = @($all | Where-Object { $kids -contains $_.ParentProcessId } | ForEach-Object { $_.ProcessId })
  foreach ($id in ($ids + $kids + $grand)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
  if ($ids.Count) { Start-Sleep -Milliseconds 800 }
}
}

if ($Uninstall) {
  Step 'removing'
  Stop-Orpheus; Ok 'Orpheus stopped'
  if (Test-Path $Menu) { Remove-Item $Menu; Ok 'Start menu entry' }
  # Run from inside the folder it is deleting, so step out of it first.
  Set-Location $env:TEMP
  # Windows lets go of a killed process's files a moment later, and a virus scan
  # of a freshly built folder can hold it too; give it a few tries.
  foreach ($i in 1..10) {
    if (-not (Test-Path $App)) { break }
    try { Remove-Item -Recurse -Force $App -ErrorAction Stop } catch { Start-Sleep 1 }
  }
  if (Test-Path $App) {
    $holders = Get-Process | Where-Object { try { $_.Modules.FileName -like "$App*" } catch { $false } } |
               ForEach-Object { "$($_.ProcessName) ($($_.Id))" }
    throw "could not remove $App; still in use by: $($holders -join ', '). Close those and run this again."
  }
  Ok 'app folder'
  Ok "done; $Home_\state is kept (delete it to forget your sign-in)"
  Note 'mpv, cava, uv and yt-dlp stay installed: winget uninstall <name> removes them'
  return
}

Step 'checking'
if (-not (Has winget)) {
  throw 'winget is missing. Install "App Installer" from the Microsoft Store, then run this again.'
}
$need = @(
  @{ cmd = 'git';    id = 'Git.Git' },
  @{ cmd = 'uv';     id = 'astral-sh.uv' },
  @{ cmd = 'mpv';    id = 'shinchiro.mpv' },
  @{ cmd = 'cava';   id = 'karlstav.cava' },
  @{ cmd = 'yt-dlp'; id = 'yt-dlp.yt-dlp' }
)
foreach ($p in $need) {
  if (Has $p.cmd) { Ok $p.cmd; continue }
  Note "installing $($p.cmd)"
  winget install --id $p.id --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null
  Refresh-Path
  if (Has $p.cmd) { Ok $p.cmd } else { Note "$($p.cmd) installed; Orpheus finds it on its own" }
}
if (-not (Has git) -or -not (Has uv)) { Refresh-Path }
if (-not (Has git)) { throw 'git did not install; install it from https://git-scm.com and run this again' }
if (-not (Has uv))  { throw 'uv did not install; see https://docs.astral.sh/uv and run this again' }

Step 'fetching'
Stop-Orpheus
if (Test-Path (Join-Path $App '.git')) {
  git -C $App pull --ff-only --quiet; Ok "updated $App"
} else {
  New-Item -ItemType Directory -Force -Path $Home_ | Out-Null
  git clone --quiet --depth 1 $Repo $App; Ok "fetched into $App"
}

Step 'building'
Push-Location $App
try { uv sync --frozen --extra desktop --quiet } finally { Pop-Location }
Ok 'python environment'
# Ask the app's own lookup, so a failure shows here and not as a silent tray icon.
$mpv = & (Join-Path $App '.venv\Scripts\python.exe') -c 'from orpheusd.system import mpv_path; print(mpv_path())'
if ($mpv -eq 'mpv' -and -not (Has mpv)) {
  throw 'mpv is not installed where Orpheus can find it. Install it (winget install shinchiro.mpv) and run this again, or set ORPHEUS_MPV to mpv.exe.'
}
Ok "mpv at $mpv"

Step 'start menu'
$py = Join-Path $App '.venv\Scripts\pythonw.exe'
$sh = (New-Object -ComObject WScript.Shell).CreateShortcut($Menu)
$sh.TargetPath = $py
$sh.Arguments = '-m orpheusd.desktop'
$sh.WorkingDirectory = $App
$sh.Description = 'Orpheus: hi-res TIDAL player and visualizers'
$sh.Save()
Ok 'Orpheus in the Start menu'

Step 'done'
Start-Process -FilePath $py -ArgumentList '-m', 'orpheusd.desktop' -WorkingDirectory $App
Write-Host '  Orpheus is in the tray: click it for the player, right-click for the visualizer.'
Write-Host '  Sign in to TIDAL from the player; the video section (8) works without it.'
