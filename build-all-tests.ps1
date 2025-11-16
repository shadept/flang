#!/usr/bin/env pwsh
# Builds all FLang test scripts using the final compiler binary (win-x64 only).
# Usage:
#   pwsh -File ./build-all-tests.ps1 [-ShowProgress]
#
# Options:
#   -ShowProgress   When set, prints per-file "[BUILD]" and "[OK]" lines.
#                   By default these are hidden; failures are always shown.

# Note: The param block must be the first non-comment statement for compatibility with older PowerShell versions.
param(
  [switch]$ShowProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve repo root as the directory where this script resides (project root)
$RepoRoot = $PSScriptRoot
Set-Location $RepoRoot

# 1) Ensure the compiler binary exists by running the build first (win-x64 only).
$BuildScript = Join-Path $RepoRoot 'build.ps1'
if (-not (Test-Path $BuildScript)) {
  Write-Error "Build script not found at $BuildScript"
  exit 1
}

function Invoke-ChildPwsh([string] $file, [string] $arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'pwsh'
  $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$file`" $arguments"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $null = $proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor Red }
  return $proc.ExitCode
}

Write-Host "== Building compiler (win-x64) ==" -ForegroundColor Cyan
$code = Invoke-ChildPwsh -file $BuildScript -arguments 'win-x64'
if ($code -ne 0) {
  Write-Error "win-x64 build failed (exit $code). See logs above."
  exit 1
}

# Locate flang binary (win-x64 only)
$Flang = Join-Path $RepoRoot 'dist\win-x64\flang.exe'
if (-not (Test-Path $Flang)) {
  Write-Error "Could not find flang.exe at dist\\win-x64\\flang.exe. Please build the final binary first."
  exit 1
}

# Discover test sources (*.f) under tests/FLang.Tests/Harness
$HarnessDir = Join-Path $RepoRoot 'tests\FLang.Tests\Harness'
if (-not (Test-Path $HarnessDir)) {
  Write-Error "Harness directory not found: $HarnessDir"
  exit 1
}

$TestFiles = Get-ChildItem -Path $HarnessDir -Recurse -Filter '*.f' | Sort-Object FullName
if ($TestFiles.Count -eq 0) {
  Write-Warning "No .f test files found under $HarnessDir"
  exit 0
}

Write-Host "Using compiler: $Flang" -ForegroundColor Cyan
Write-Host "Discovered $($TestFiles.Count) test script(s). Starting build..." -ForegroundColor Cyan

$Total = 0
$Passed = 0
$Failed = 0
$FailedList = @()

foreach ($file in $TestFiles) {
  $Total++
  $rel = Resolve-Path -LiteralPath $file.FullName | ForEach-Object { $_.Path.Replace($RepoRoot + '\\','') }
  if ($ShowProgress) { Write-Host "[BUILD] $rel" -ForegroundColor Yellow }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Flang
  # Only build; rely on default stdlib resolution near the binary. Use --release for optimized C backend.
  # Also emit FIR next to the source file
  $firPath = [System.IO.Path]::ChangeExtension($file.FullName, 'fir')
  $psi.Arguments = '"' + $file.FullName + '" --release --emit-fir ' + '"' + $firPath + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $null = $proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $code = $proc.ExitCode

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor Red }

  if ($code -eq 0) {
    $Passed++
    if ($ShowProgress) { Write-Host "[OK]    $rel" -ForegroundColor Green }
  } else {
    $Failed++
    $FailedList += $rel
    Write-Host "[FAIL]  $rel (exit $code)" -ForegroundColor Red
  }
}

Write-Host "Build summary: $Passed passed, $Failed failed, $Total total" -ForegroundColor Cyan
exit 0
