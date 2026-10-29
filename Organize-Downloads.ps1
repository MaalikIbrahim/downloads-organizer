# Organize-Downloads.ps1
#
# Sorts every loose file in a folder (default: your Downloads) into subfolders
# using name rules from rules.json.
#
#  - Nothing is ever deleted.
#  - Exact duplicates (same SHA-256 as a file already filed anywhere in the
#    folder) go to "_Duplicates to delete" so you can review and delete them.
#  - Same name but different content at the destination: the newer file becomes
#    the current one and the older copy goes into that folder's "Old Versions",
#    stamped with its last-modified date.
#  - Files no rule matches go to "_Unsorted\<type>" so nothing is left loose.
#  - Files that are open in another app can't be moved: they are listed at the
#    end. Close them and run again.
#
# Usage:
#   .\Organize-Downloads.ps1                 # sort Downloads using rules.json
#   .\Organize-Downloads.ps1 -Preview        # show what would move, move nothing
#   .\Organize-Downloads.ps1 -Path D:\Inbox -RulesFile .\my-rules.json

[CmdletBinding()]
param(
  [string]$Path = (Join-Path $HOME 'Downloads'),
  [string]$RulesFile = (Join-Path $PSScriptRoot 'rules.json'),
  [switch]$Preview
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Folder not found: $Path" }
if (-not (Test-Path -LiteralPath $RulesFile)) {
  throw "Rules file not found: $RulesFile (copy rules.example.json to rules.json and edit it)"
}

$config = Get-Content -LiteralPath $RulesFile -Raw | ConvertFrom-Json
$root = (Resolve-Path -LiteralPath $Path).Path
$dupDir = '_Duplicates to delete'

# Files the script never touches
$keep = @('desktop.ini', 'Organize-Downloads.ps1', 'Run-Organize-Downloads.cmd', 'Preview-Organize-Downloads.cmd', 'rules.json')
$ignorePattern = '^~\$|\.(crdownload|part|partial|tmp|download)$'

# 1) Exact file name -> folder (one-off files whose names don't say where they belong)
$overrides = @{}
if ($config.overrides) {
  $config.overrides.PSObject.Properties | ForEach-Object { $overrides[$_.Name] = $_.Value }
}

# 2) Regex rules, checked top to bottom. First match wins. Case-insensitive.
$rules = @($config.rules)

# 3) Fallback by file type into _Unsorted
$fallback = @(
  @('docx?|odt|rtf|txt|md', 'Documents'),
  @('xlsx?|xlsm|csv|ods', 'Spreadsheets'),
  @('pdf', 'PDFs'),
  @('pptx?', 'Presentations'),
  @('jpe?g|png|gif|bmp|webp|heic|svg', 'Images'),
  @('mp4|mov|avi|mkv|wmv|webm', 'Videos'),
  @('zip|7z|rar|tar|gz', 'Archives'),
  @('exe|msi|msix|msixbundle|appx|appxbundle', 'Installers')
)

# ---------------------------------------------------------------------------

function Get-Destination([string]$name) {
  if ($overrides.ContainsKey($name)) { return $overrides[$name] }
  foreach ($r in $rules) { if ($name -match $r.pattern) { return $r.folder } }
  $ext = [IO.Path]::GetExtension($name).TrimStart('.')
  foreach ($f in $fallback) { if ($ext -match ('^(' + $f[0] + ')$')) { return '_Unsorted\' + $f[1] } }
  return '_Unsorted\Other'
}

function Get-UniquePath([string]$dir, [string]$name) {
  $p = Join-Path $dir $name
  if (-not (Test-Path -LiteralPath $p)) { return $p }
  $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name)
  $i = 2
  while (Test-Path -LiteralPath (Join-Path $dir "$base ($i)$ext")) { $i++ }
  return (Join-Path $dir "$base ($i)$ext")
}

function Get-OldVersionPath([string]$destDir, $item) {
  $oldDir = Join-Path $destDir 'Old Versions'
  $base = [IO.Path]::GetFileNameWithoutExtension($item.Name); $ext = [IO.Path]::GetExtension($item.Name)
  $stamped = '{0} ({1}){2}' -f $base, $item.LastWriteTime.ToString('yyyy-MM-dd'), $ext
  return (Get-UniquePath $oldDir $stamped)
}

$hashCache = @{}
function Get-Hash([string]$p) {
  if ($hashCache.ContainsKey($p)) { return $hashCache[$p] }
  try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $h = $null }
  $hashCache[$p] = $h
  return $h
}

$locked = New-Object System.Collections.ArrayList
$count = @{ Moved = 0; Duplicates = 0; OldVersions = 0; Unsorted = 0; Locked = 0 }

function Move-One([string]$from, [string]$to, [string]$label) {
  $rel = $to.Substring($root.Length + 1)
  if ($Preview) { Write-Host ("[preview] {0}: {1} -> {2}" -f $label, (Split-Path $from -Leaf), $rel) -ForegroundColor Gray; return $true }
  try {
    New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
    Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
    Write-Host ("{0}: {1} -> {2}" -f $label, (Split-Path $from -Leaf), $rel) -ForegroundColor Green
    return $true
  } catch {
    [void]$locked.Add((Split-Path $from -Leaf))
    $count.Locked++
    Write-Host ("Could not move (open in another app?): {0}" -f (Split-Path $from -Leaf)) -ForegroundColor Red
    return $false
  }
}

# Index every file already filed in a subfolder, by size, for duplicate checks
$dupRoot = Join-Path $root $dupDir
$bySize = @{}
Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.DirectoryName -ne $root -and -not $_.FullName.StartsWith($dupRoot) -and $_.Name -notmatch $ignorePattern } |
  ForEach-Object {
    if (-not $bySize.ContainsKey($_.Length)) { $bySize[$_.Length] = New-Object System.Collections.ArrayList }
    [void]$bySize[$_.Length].Add($_.FullName)
  }

$loose = Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
  Where-Object { $keep -notcontains $_.Name -and $_.Name -notmatch $ignorePattern } |
  Sort-Object LastWriteTime

if (-not $loose) { Write-Host 'Folder is already tidy. Nothing to move.' -ForegroundColor Cyan }

foreach ($file in $loose) {
  $src = $file.FullName

  # Exact duplicate of something already filed? (size first, then SHA-256)
  $isDup = $false
  if ($bySize.ContainsKey($file.Length)) {
    $h = Get-Hash $src
    if ($h) { foreach ($other in $bySize[$file.Length]) { if ((Get-Hash $other) -eq $h) { $isDup = $true; $dupOf = $other; break } } }
  }
  if ($isDup) {
    $to = Get-UniquePath $dupRoot $file.Name
    if (Move-One $src $to ('Duplicate of ' + $dupOf.Substring($root.Length + 1))) { $count.Duplicates++ }
    continue
  }

  $folder = Get-Destination $file.Name
  $destDir = Join-Path $root $folder
  $target = Join-Path $destDir $file.Name

  if (Test-Path -LiteralPath $target) {
    # Same name, different content: newer one stays current, older goes to Old Versions
    $existing = Get-Item -LiteralPath $target
    if ($file.LastWriteTime -gt $existing.LastWriteTime) {
      $oldPath = Get-OldVersionPath $destDir $existing
      if (Move-One $target $oldPath 'Older copy to Old Versions') {
        $count.OldVersions++
        if (Move-One $src $target 'Moved (newer version)') { $count.Moved++ }
      }
    } else {
      $oldPath = Get-OldVersionPath $destDir $file
      if (Move-One $src $oldPath 'Older copy to Old Versions') { $count.OldVersions++ }
      $target = $oldPath
    }
  } else {
    $label = if ($folder -like '_Unsorted*') { 'Unsorted (no rule yet)' } else { 'Moved' }
    if (Move-One $src $target $label) { if ($folder -like '_Unsorted*') { $count.Unsorted++ } else { $count.Moved++ } }
  }

  # Add to the index so identical loose files later in this run are caught as duplicates
  if (-not $bySize.ContainsKey($file.Length)) { $bySize[$file.Length] = New-Object System.Collections.ArrayList }
  [void]$bySize[$file.Length].Add($target)
  if ($hashCache.ContainsKey($src)) { $hashCache[$target] = $hashCache[$src] }
}

Write-Host ''
$mode = if ($Preview) { 'Preview only, nothing was moved.' } else { 'Done. Nothing was deleted.' }
Write-Host $mode -ForegroundColor Cyan
Write-Host ("Filed: {0}   Duplicates: {1}   Older copies to Old Versions: {2}   Unsorted: {3}   Couldn't move: {4}" -f `
  $count.Moved, $count.Duplicates, $count.OldVersions, $count.Unsorted, $count.Locked) -ForegroundColor Cyan
if ($count.Unsorted -gt 0) { Write-Host "Check '_Unsorted' and add rules to rules.json for anything that keeps landing there." -ForegroundColor Yellow }
if ($locked.Count -gt 0) { Write-Host ("Close these and run again: " + ($locked -join ', ')) -ForegroundColor Yellow }
Write-Host "Review and delete the contents of '_Duplicates to delete' yourself when ready." -ForegroundColor Cyan
