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

function Parse-TestMetadata([string] $filePath) {
  $metadata = @{
    TestName = ''
    ExpectedExitCode = $null
    ExpectedStdout = @()
    ExpectedStderr = @()
    ExpectedCompileErrors = @()
  }

  $content = Get-Content -Path $filePath -Encoding UTF8
  foreach ($line in $content) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^//!\s*(.+)$') {
      $directive = $matches[1].Trim()

      if ($directive -match '^TEST:\s*(.+)$') {
        $metadata.TestName = $matches[1].Trim()
      }
      elseif ($directive -match '^EXIT:\s*(.+)$') {
        $metadata.ExpectedExitCode = [int]$matches[1].Trim()
      }
      elseif ($directive -match '^STDOUT:\s*(.+)$') {
        $metadata.ExpectedStdout += $matches[1].Trim()
      }
      elseif ($directive -match '^STDERR:\s*(.+)$') {
        $metadata.ExpectedStderr += $matches[1].Trim()
      }
      elseif ($directive -match '^COMPILE-ERROR:\s*(.+)$') {
        $metadata.ExpectedCompileErrors += $matches[1].Trim()
      }
      elseif ($directive -match '^COMPILE-ERROR$') {
        # Handle the case where COMPILE-ERROR has no specific code
        $metadata.ExpectedCompileErrors += ''
      }
    }
  }

  return $metadata
}

function Normalize-Output([string] $text) {
  # Split into lines, trim trailing whitespace and carriage returns
  $lines = $text -split "`n" | ForEach-Object {
    $_.TrimEnd("`r").TrimEnd()
  } | Where-Object { $_ -ne '' }
  return $lines
}

function Resolve-ExecutablePath([string] $sourceFile) {
  $base = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile)
  $dir = [System.IO.Path]::GetDirectoryName($sourceFile)

  # Try .exe first on Windows
  $exePath = Join-Path $dir "$base.exe"
  if (Test-Path $exePath) {
    return $exePath
  }

  # Try without extension
  $exePath = Join-Path $dir $base
  if (Test-Path $exePath) {
    return $exePath
  }

  return $null
}

function Render-ProgressBar([int] $current, [int] $total) {
  if ($total -le 0) { return }

  $width = 40
  $percent = [Math]::Min(100, ($current * 100) / $total)
  $filled = [Math]::Min($width, ($current * $width) / $total)
  $empty = $width - $filled

  $filledBar = '#' * $filled
  $emptyBar = '-' * $empty

  Write-Host "`r[$filledBar$emptyBar] $current/$total ($percent%)" -NoNewline
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

Render-ProgressBar -current 0 -total $TestFiles.Count

foreach ($file in $TestFiles) {
  $Total++
  $rel = $file.FullName.Replace("$RepoRoot\", '')

  $metadata = Parse-TestMetadata -filePath $file.FullName
  $expectCompileFail = $metadata.ExpectedCompileErrors.Count -gt 0

  if ($ShowProgress) {
    Write-Host "`r$(' ' * 80)`r" -NoNewline  # Clear progress bar
    if ($metadata.TestName) {
      Write-Host "[BUILD] $rel :: $($metadata.TestName)" -ForegroundColor Yellow
    } else {
      Write-Host "[BUILD] $rel" -ForegroundColor Yellow
    }
  }

  # Compile the test
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Flang
  $firPath = [System.IO.Path]::ChangeExtension($file.FullName, 'fir')
  $psi.Arguments = "`"$($file.FullName)`" --release --emit-fir `"$firPath`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $null = $proc.Start()

  # Read asynchronously to avoid deadlock
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $proc.WaitForExit()
  $compileStdout = $stdoutTask.Result
  $compileStderr = $stderrTask.Result
  $compileExitCode = $proc.ExitCode

  $compileOutput = $compileStdout + $compileStderr
  $compileSucceeded = ($compileExitCode -eq 0)

  $failureMessages = @()
  $expectedFailureSatisfied = $false

  if ($compileSucceeded) {
    if ($expectCompileFail) {
      $failureMessages += "Expected compile failure with codes: $($metadata.ExpectedCompileErrors -join ', '), but compilation succeeded"
    } else {
      # Compilation succeeded as expected - now run the executable
      $exePath = Resolve-ExecutablePath -sourceFile $file.FullName

      if (-not $exePath) {
        $failureMessages += "FLang.CLI did not produce an executable for $rel"
      } else {
        # Run the executable
        $runPsi = New-Object System.Diagnostics.ProcessStartInfo
        $runPsi.FileName = $exePath
        $runPsi.UseShellExecute = $false
        $runPsi.RedirectStandardOutput = $true
        $runPsi.RedirectStandardError = $true

        $runProc = New-Object System.Diagnostics.Process
        $runProc.StartInfo = $runPsi
        $null = $runProc.Start()

        # Read asynchronously to avoid deadlock
        $runStdoutTask = $runProc.StandardOutput.ReadToEndAsync()
        $runStderrTask = $runProc.StandardError.ReadToEndAsync()
        $runProc.WaitForExit()
        $runStdout = $runStdoutTask.Result
        $runStderr = $runStderrTask.Result
        $runExitCode = $runProc.ExitCode

        # Validate exit code
        if ($null -ne $metadata.ExpectedExitCode) {
          if ($runExitCode -ne $metadata.ExpectedExitCode) {
            $failureMessages += "Expected exit code $($metadata.ExpectedExitCode) but got $runExitCode"
          }
        }

        # Validate stdout
        if ($metadata.ExpectedStdout.Count -gt 0) {
          $actualStdout = Normalize-Output -text $runStdout
          foreach ($expectedLine in $metadata.ExpectedStdout) {
            if ($actualStdout -notcontains $expectedLine) {
              $failureMessages += "Missing expected STDOUT line: $expectedLine"
            }
          }
        }

        # Validate stderr
        if ($metadata.ExpectedStderr.Count -gt 0) {
          $actualStderr = Normalize-Output -text $runStderr
          foreach ($expectedLine in $metadata.ExpectedStderr) {
            if ($actualStderr -notcontains $expectedLine) {
              $failureMessages += "Missing expected STDERR line: $expectedLine"
            }
          }
        }
      }
    }
  } else {
    # Compilation failed
    if ($expectCompileFail) {
      # Expected failure - check for error codes
      $missingCodes = @()
      foreach ($code in $metadata.ExpectedCompileErrors) {
        if ($code -and $compileOutput -notlike "*$code*") {
          $missingCodes += $code
        }
      }

      if ($missingCodes.Count -eq 0) {
        $expectedFailureSatisfied = $true
      } else {
        $failureMessages += "Missing expected error codes: $($missingCodes -join ', ')"
      }
    } else {
      $failureMessages += "Compilation failed for $rel"
    }
  }

  # Determine pass/fail
  if ($failureMessages.Count -eq 0) {
    $Passed++
    if ($ShowProgress) {
      Write-Host "`r$(' ' * 80)`r" -NoNewline  # Clear progress bar
      if ($expectedFailureSatisfied) {
        Write-Host "[OK]    $rel (expected compile error)" -ForegroundColor Green
      } else {
        Write-Host "[OK]    $rel" -ForegroundColor Green
      }
    }
  } else {
    $Failed++
    $FailedList += $rel
    Write-Host "`r$(' ' * 80)`r" -NoNewline  # Clear progress bar

    foreach ($msg in $failureMessages) {
      Write-Host $msg -ForegroundColor Red
    }

    if ($compileOutput) {
      Write-Host "--- Compiler Output: $rel ---" -ForegroundColor Red
      Write-Host $compileOutput
    }

    if ($runStdout) {
      Write-Host "--- Program STDOUT: $rel ---" -ForegroundColor Red
      Write-Host $runStdout
    }

    if ($runStderr) {
      Write-Host "--- Program STDERR: $rel ---" -ForegroundColor Red
      Write-Host $runStderr
    }

    Write-Host "[FAIL]  $rel" -ForegroundColor Red
  }

  Render-ProgressBar -current $Total -total $TestFiles.Count
}

Write-Host ""  # New line after progress bar
Write-Host "Build summary: $Passed passed, $Failed failed, $Total total" -ForegroundColor Cyan

if ($Failed -gt 0) {
  if ($FailedList.Count -gt 0) {
    Write-Host "Failed scripts:" -ForegroundColor Red
    foreach ($f in $FailedList) {
      Write-Host " - $f" -ForegroundColor Red
    }
  }
  exit 1
}

exit 0
