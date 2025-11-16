#!/usr/bin/env pwsh
# Simple build script for FLang — produces Release artifacts and fills ./dist as configured
# Usage:
#   pwsh -File ./build.ps1 [RID]
# Examples:
#   pwsh -File ./build.ps1            # builds for default RID (win-x64)
#   pwsh -File ./build.ps1 win-x64    # builds Windows x64
#   pwsh -File ./build.ps1 linux-x64  # builds Linux x64 (on a machine/CI that can cross-publish)

# Note: The param block must be the first non-comment statement for compatibility with older PowerShell versions.
param(
  [Parameter(Position = 0)]
  [string]$RID = 'win-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compatibility: $PSScriptRoot is not defined in very old Windows PowerShell hosts when dot-sourced.
if (-not $PSScriptRoot) {
  $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Resolve repo root as the directory where this script resides (project root)
$RepoRoot = $PSScriptRoot
Set-Location $RepoRoot

Write-Host "=== Building FLang.CLI (Release) for RID=$RID ===" -ForegroundColor Cyan
Write-Host

function Fail($msg, [int]$code = 1) {
  Write-Host
  Write-Error $msg
  exit $code
}

# Restore solution packages (optional but explicit)
& dotnet restore "flang.sln"
if ($LASTEXITCODE -ne 0) { Fail "Build failed during 'dotnet restore'. See errors above." $LASTEXITCODE }

# Publish FLang.CLI; the .csproj is already configured to produce a single-file, self-contained exe
# and copy the final artifact to ./dist/<RID>/flang.exe along with ./dist/<RID>/stdlib/**
& dotnet publish "src\FLang.CLI\FLang.CLI.csproj" -c Release -r $RID -nologo
if ($LASTEXITCODE -ne 0) { Fail "Build failed during 'dotnet publish'. See errors above." $LASTEXITCODE }

$DistDir = Join-Path $RepoRoot (Join-Path 'dist' $RID)
$FinalExe = Join-Path $DistDir 'flang.exe'

Write-Host
if (Test-Path $FinalExe) {
  $fileInfo = Get-Item $FinalExe
  $size = $fileInfo.Length
  Write-Host ("Success: {0} ({1} bytes)" -f $FinalExe, $size)
  $StdlibDir = Join-Path $DistDir 'stdlib'
  if (Test-Path $StdlibDir) {
    Write-Host "Stdlib copied to: $StdlibDir" 
  } else {
    Write-Host "Note: stdlib folder not found at $StdlibDir"
  }
  Write-Host
  Write-Host "Done." -ForegroundColor Green
  exit 0
} else {
  Write-Warning "Expected final artifact was not found at $FinalExe"
  Write-Host "The publish may have succeeded, but the post-publish copy step might have been skipped."
  Write-Host "Check the publish logs and the MSBuild target in src\FLang.CLI\FLang.CLI.csproj."
  exit 1
}
