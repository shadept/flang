# Acceptance check for the RFC-025 profiler. Builds this project with `flang -p`, runs the
# ground-truth workload (src/main.f), and asserts the flat table and folded output against known
# call counts and spin budgets. Run from this directory:
#
#   pwsh ./check.ps1 [-Flang <path-to-flang.exe>]
#
# Three runs:
#   A  plain: exact call counts, self/inclusive accuracy, folded-file invariants
#   B  PROFCHECK_PHASES=1: dump()/reset() window separation
#   C  FLANG_PROFILE_DEPTH=16: stack overflow must degrade gracefully, never corrupt
param(
    [string]$Flang = "$PSScriptRoot\..\..\dist\win-x64\flang.exe"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$stdlib = Resolve-Path "$PSScriptRoot\..\..\stdlib"
$failures = @()
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  ok: $msg" }
    else { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:failures += $msg }
}
function Near($actual, $expected, $relTol, $msg) {
    $lo = $expected * (1 - $relTol); $hi = $expected * (1 + $relTol)
    Assert ($actual -ge $lo -and $actual -le $hi) "$msg (got $([math]::Round($actual,1)), want $expected +/-$($relTol*100)%)"
}

# Parse "calls self incl ns/call name" rows into a map keyed by a name fragment.
function Parse-Table($lines) {
    $rows = @{}
    foreach ($l in $lines) {
        if ($l -match '^\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\S+)\s*$') {
            $rows[$Matches[5]] = [pscustomobject]@{
                calls = [int64]$Matches[1]; self = [double]$Matches[2]
                incl = [double]$Matches[3]; name = $Matches[5]
            }
        }
    }
    return $rows
}
function Row($rows, $frag) {
    $hit = $rows.Values | Where-Object { $_.name -like "*$frag*" }
    if (-not $hit) { return $null }
    return $hit | Select-Object -First 1
}

Write-Host "build (-p)..."
& $Flang -p -s $stdlib build 2>&1 | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { throw "profiled build failed" }

# ---- Run A: plain -------------------------------------------------------
Write-Host "`nrun A: counts, times, folded"
$env:FLANG_PROFILE_OUT = "$PSScriptRoot\build\check.folded"
& .\build\profiler_check.exe 1> build\ground.txt 2> build\profile.txt
$exitA = $LASTEXITCODE
$env:FLANG_PROFILE_OUT = $null
Assert ($exitA -eq 0) "run A exits 0"

$ground = Get-Content build\ground.txt
$wall = [double]($ground[[array]::IndexOf($ground, "GROUND wall_ms") + 1])
$rows = Parse-Table (Get-Content build\profile.txt)

foreach ($t in @(@(".spin_leaf_a(", 300), @(".spin_leaf_b(", 150), @(".middle(", 100),
                 @(".deep_recur(", 51), @(".ping(", 210), @(".pong(", 200),
                 @(".maybe_fail(", 50), @(".try_some(", 50))) {
    $r = Row $rows $t[0]
    Assert ($null -ne $r -and $r.calls -eq $t[1]) "calls $($t[0]) == $($t[1]) (got $(if ($r) { $r.calls } else { 'missing' }))"
}

# Self-time budgets from the spins (ms). Generous tolerance: spin granularity + scheduler.
Near (Row $rows ".spin_leaf_a(").self 300 0.25 "self leaf_a ~300ms (300 x 1ms)"
Near (Row $rows ".spin_leaf_b(").self 300 0.25 "self leaf_b ~300ms (150 x 2ms)"
Near (Row $rows ".middle(").self   100 0.35 "self middle ~100ms (own spin only)"
Near (Row $rows ".ping(").self     210 0.30 "self ping ~210ms (210 x 1ms)"
Near (Row $rows ".pong(").self     600 0.30 "self pong ~600ms (200 x 3ms)"
Near (Row $rows ".maybe_fail(").self 50 0.40 "self maybe_fail ~50ms"

# The mutual-recursion smear regression: ping/pong self must track their own spins (ratio 0.35),
# not whichever frame sat between re-entries.
$ratio = (Row $rows ".ping(").self / (Row $rows ".pong(").self
Assert ($ratio -gt 0.2 -and $ratio -lt 0.55) "ping/pong self ratio ~0.35 (got $([math]::Round($ratio,2)))"

# Inclusive: counted once per outermost span, never per recursion level.
Near (Row $rows ".middle(").incl 500 0.25 "incl middle ~500ms"
$dr = Row $rows ".deep_recur("
Assert ($dr.incl -gt 40 -and $dr.incl -lt 90) "incl deep_recur ~51ms, once (got $([math]::Round($dr.incl,1)))"
$pi = Row $rows ".ping("
Assert ($pi.incl -gt 650 -and $pi.incl -lt 1000) "incl ping ~810ms, not multiplied (got $([math]::Round($pi.incl,1)))"
$mainRow = Row $rows " main"
if (-not $mainRow) { $mainRow = $rows["main"] }
Assert ($null -ne $mainRow -and [math]::Abs($mainRow.incl - $wall) -lt $wall * 0.15) "incl main ~wall $wall ms (got $(if ($mainRow) { [math]::Round($mainRow.incl,1) } else { 'missing' }))"

# Conservation: total self across the table accounts for the measured wall.
$sumSelf = ($rows.Values | Measure-Object -Property self -Sum).Sum
Near $sumSelf $wall 0.15 "sum(self) ~wall"

# Folded-file invariants.
$folded = Get-Content build\check.folded
Assert ($folded.Count -gt 0) "folded file non-empty"
$badFormat = 0; $badRoot = 0; $foldedByFunc = @{}
foreach ($l in $folded) {
    if ($l -notmatch '^(\S+) (\d+)$') { $badFormat++; continue }
    $chain = $Matches[1] -split ';'
    $ns = [int64]$Matches[2]
    if ($chain[0] -ne "main") { $badRoot++ }
    $leaf = $chain[-1]
    if (-not $foldedByFunc.ContainsKey($leaf)) { $foldedByFunc[$leaf] = [int64]0 }
    $foldedByFunc[$leaf] += $ns
    if ($ns -le 0) { $badFormat++ }
}
Assert ($badFormat -eq 0) "every folded line is 'frames <positive int>' with space-free frames"
Assert ($badRoot -eq 0) "every folded chain starts at main"

# Folded self per function agrees with the flat table (both derive from the same nodes).
foreach ($frag in @(".spin_leaf_a(", ".pong(", ".middle(")) {
    $r = Row $rows $frag
    $sum = ([int64]0)
    foreach ($k in $foldedByFunc.Keys) { if ($k -like "*$frag*") { $sum += $foldedByFunc[$k] } }
    Near ($sum / 1e6) $r.self 0.1 "folded self sum matches table for $frag"
}

# ---- Run B: dump() / reset() window separation --------------------------
Write-Host "`nrun B: phases"
$env:PROFCHECK_PHASES = "1"
& .\build\profiler_check.exe 1> build\ground2.txt 2> build\profile2.txt
$exitB = $LASTEXITCODE
$env:PROFCHECK_PHASES = $null
Assert ($exitB -eq 0) "run B exits 0"
$all2 = Get-Content build\profile2.txt -Raw
$tables = ($all2 -split "flang profile:").Count - 1
Assert ($tables -eq 2) "two tables (mid-run dump + exit dump), got $tables"
$second = Parse-Table (($all2 -split "flang profile:")[2] -split "`n")
$la2 = Row $second ".spin_leaf_a("
Assert ($null -ne $la2 -and $la2.calls -eq 20) "post-reset window: leaf_a calls == 20 (got $(if ($la2) { $la2.calls } else { 'missing' }))"
Near $la2.self 20 0.5 "post-reset window: leaf_a self ~20ms"
$mf2 = Row $second ".maybe_fail("
Assert ($null -eq $mf2 -or $mf2.calls -eq 0) "post-reset window excludes window-one work"

# ---- Run C: forced stack overflow ---------------------------------------
Write-Host "`nrun C: depth overflow degrades gracefully"
$env:FLANG_PROFILE_DEPTH = "16"
& .\build\profiler_check.exe 1> $null 2> build\profile3.txt
$exitC = $LASTEXITCODE
$env:FLANG_PROFILE_DEPTH = $null
Assert ($exitC -eq 0) "run C exits 0 under depth pressure"
Assert ((Get-Content build\profile3.txt -Raw) -match "TRUNCATED") "truncation is reported, not silent"
$rows3 = Parse-Table (Get-Content build\profile3.txt)
$la3 = Row $rows3 ".spin_leaf_a("
Assert ($null -ne $la3 -and $la3.calls -eq 300) "shallow counts survive deep-stack truncation"

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}
Write-Host "all checks passed" -ForegroundColor Green
exit 0
