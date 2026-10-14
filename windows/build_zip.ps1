<#
Builds a patched copy of the mod zip from the ORIGINAL zip + an overlay folder (output of apply.py / patch_phone_nav.py).

  powershell -ExecutionPolicy Bypass -File build_zip.ps1 -Source <original.zip> -Overlay <folder> -Output <new.zip>

Two traps this script avoids (both cost us hours):
 1. .NET ZipArchive in Update mode rewrites EMPTY entries as broken records (method=stored, csize=2, usize=0).
    RLS ships 16 zero-byte "switch-off" files (e.g. levels/west_coast_usa/dynamicAudioEmitters/ribbonData.audioSFX.json);
    BeamNG skips the broken entry, loads the vanilla file instead -> audioRibbon.lua error -> endless level loading.
    So we always write a NEW archive in Create mode, empty files with NoCompression.
 2. BeamNG 0.39's runtime Vue compiler caches compiled components by file timestamp. If a replaced file keeps the
    original LastWriteTime, the game keeps showing the old component. Replaced entries get LastWriteTime = now.
#>
param(
  [Parameter(Mandatory=$true)][string]$Source,
  [Parameter(Mandatory=$true)][string]$Overlay,
  [Parameter(Mandatory=$true)][string]$Output
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (Get-Process -Name 'BeamNG.drive.x64' -ErrorAction SilentlyContinue) { 'Close the game first.'; exit 2 }
$Overlay = (Resolve-Path $Overlay).Path
if (Test-Path $Output) { Remove-Item $Output -Force }
$in  = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $Source).Path)
$fs  = [IO.File]::Open($Output, 'CreateNew')
$out = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
$rep = 0; $cp = 0; $empty = 0
foreach ($e in $in.Entries) {
  $name = $e.FullName
  if ($name.EndsWith('/')) {
    $ne = $out.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression); $ne.LastWriteTime = $e.LastWriteTime; continue
  }
  $pf = Join-Path $Overlay ($name.Replace('/', '\'))
  $isRep = $false
  if (Test-Path -LiteralPath $pf) { $bytes = [IO.File]::ReadAllBytes($pf); $rep++; $isRep = $true }
  else { $ms = New-Object IO.MemoryStream; $s = $e.Open(); $s.CopyTo($ms); $s.Close(); $bytes = $ms.ToArray(); $cp++ }
  $lvl = if ($bytes.Length -eq 0) { $empty++; [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Optimal }
  $ne = $out.CreateEntry($name, $lvl)
  $ne.LastWriteTime = if ($isRep) { [DateTimeOffset]::Now } else { $e.LastWriteTime }
  $w = $ne.Open(); if ($bytes.Length -gt 0) { $w.Write($bytes, 0, $bytes.Length) }; $w.Close()
}
$out.Dispose(); $fs.Close(); $in.Dispose()
$ovl = (Get-ChildItem $Overlay -Recurse -File).Count
"replaced=$rep (overlay files: $ovl) copied=$cp empty=$empty size=" + (Get-Item $Output).Length
if ($rep -ne $ovl) { "WARNING: some overlay files have no matching entry in the source zip (different mod version?)" }
