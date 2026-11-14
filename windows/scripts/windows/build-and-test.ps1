<#
  Builds every project of the Windows app and runs every test project, on a Windows machine.
  Nothing is installed, signed, published or pushed; the app is not started.

  Run from any folder (PowerShell 7 or Windows PowerShell 5.1):
    pwsh -NoProfile -ExecutionPolicy Bypass -File windows\scripts\windows\build-and-test.ps1
  Options:
    -Configuration Release     (default Debug)
    -Platform ARM64            (default x64; used for the WinUI app and its proofs)
    -CloudOnly                 build Core + Core.Tests and run only the Cloud tests (fast check)
    -RealPc                    run ONLY the tests that need a real PC (installed Claude Code, Codex and Gemini CLIs);
                               they fail the run here. One command for a developer PC:
                                 pwsh -File windows\scripts\windows\build-and-test.ps1 -RealPc
    -LinkNative <folder>       a folder holding tdlink.dll + libwebrtc.dll (the release workflow builds it first).
                               Without it the engine is built here by src\TerminalDeck.Link.Native\build.ps1
                               (downloads the pinned libwebrtc, needs the C++ build tools).

  Test groups (xUnit trait "Group"):
    (none)   the gate: every test must pass.
    RealPc   needs installed Claude Code, Codex and Gemini CLIs. Run, listed by name with its result, never hidden;
             it fails the run only with -RealPc.
    Unix     checks the Linux server helper script with /bin/sh; runs on Mac and Linux. Listed by name here.

  Needs: the .NET SDK named in global.json (10.0.4xx); for the WinUI projects Visual Studio 2022+ or the Build Tools
  with the "Windows application development" workload; Python 3 on PATH (the chat tests' fake CLIs are Python).
  Test scratch data goes under C:\TD\out\windows-check\<time> (some Windows tests only accept a root there).
  Results land in windows\.artifacts\windows-check\ (one .trx per test project and summary.txt).
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
  [ValidateSet('x64', 'ARM64')] [string] $Platform = 'x64',
  [switch] $CloudOnly,
  [switch] $RealPc,
  [string] $LinkNative = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $root '.artifacts\windows-check'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$summary = Join-Path $out 'summary.txt'
Set-Content -Path $summary -Value "Windows check $(Get-Date -Format o)  configuration=$Configuration platform=$Platform"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

function Note([string] $line) { Write-Host $line; Add-Content -Path $summary -Value $line }

# Every test in a .trx: name and outcome.
function Results([string] $trx) {
  if (-not (Test-Path $trx)) { return @() }
  $xml = [xml](Get-Content -Raw -LiteralPath $trx)
  @($xml.GetElementsByTagName('UnitTestResult') | ForEach-Object { [pscustomobject]@{ Name = $_.testName; Outcome = $_.outcome } })
}

# 1. The SDK global.json asks for.
$wanted = (Get-Content (Join-Path $root 'global.json') -Raw | ConvertFrom-Json).sdk.version
$have = (& dotnet --version) 2>$null
if (-not $have) { throw "No .NET SDK found. Install the .NET SDK $wanted (https://dotnet.microsoft.com/download/dotnet/10.0)." }
$w = $wanted -split '\.'; $h = ($have -split '-')[0] -split '\.'
$sameBand = $w[0] -eq $h[0] -and $w[1] -eq $h[1] -and [math]::Floor([int]$w[2] / 100) -eq [math]::Floor([int]$h[2] / 100) -and [int]$h[2] -ge [int]$w[2]
if (-not $sameBand) { throw "global.json wants SDK $wanted (or a later patch of the same band); this machine has $have." }
Note "SDK $have (global.json $wanted)"

Push-Location $root
try {
  # 2. Build. Plain .NET (net10.0) and Windows-only (net10.0-windows); WinUI ones need -p:Platform.
  $all = git ls-files '*.csproj' | ForEach-Object { $_ -replace '/', '\' }
  if ($CloudOnly) { $all = @('src\TerminalDeck.Core\TerminalDeck.Core.csproj', 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj') }
  $failedBuilds = @(); $failedTests = @()

  foreach ($project in $all) {
    $text = Get-Content $project -Raw
    $cmd = @('build', $project, '-c', $Configuration, '-nologo', '-v', 'minimal')
    if ($text -match 'UseWinUI|WindowsAppSDK|<Platforms>') { $cmd += "-p:Platform=$Platform" }
    & dotnet @cmd
    if ($LASTEXITCODE -ne 0) { $failedBuilds += $project; Note "BUILD FAIL  $project" } else { Note "BUILD OK    $project" }
  }

  # 3. What the Windows tests need on this machine: the keeper and chat worker just built, scratch roots, the
  #    direct-link engine next to the tests.
  if (-not $CloudOnly) {
    $scratch = Join-Path 'C:\TD\out\windows-check' (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    function Built([string] $folder, [string] $file) {
      $found = @(Get-ChildItem -Path (Join-Path $root $folder) -Recurse -Filter $file -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\bin\\$Configuration\\" -and $_.FullName -notmatch '\\(ref|obj)\\' } | Sort-Object LastWriteTime -Descending)
      if ($found.Count -eq 0) { throw "$file was not built under $folder." }
      $found[0].FullName
    }
    $env:TD_KEEPER_EXE = Built 'src\TerminalDeck.Keeper' 'TerminalDeck.Keeper.exe'
    $env:TD_CHAT_WORKER_HOST = Built 'tests\TerminalDeck.Chat.WorkerHost' 'TerminalDeck.Chat.WorkerHost.exe'
    foreach ($pair in @(@('TD_HOOT_TEST_ROOT', 'hoot'), @('TD_SERVERS_PROOF_ROOT', 'servers'), @('TD_CHAT_PROOF_ROOT', 'chat'))) {
      $folder = Join-Path $scratch $pair[1]; New-Item -ItemType Directory -Force -Path $folder | Out-Null
      Set-Item -Path "env:$($pair[0])" -Value $folder
    }
    Note "Scratch $scratch; keeper $env:TD_KEEPER_EXE; chat worker $env:TD_CHAT_WORKER_HOST"

    if (-not $LinkNative) {
      $LinkNative = Join-Path $root '.artifacts\link-native'
      if (-not ((Test-Path (Join-Path $LinkNative 'tdlink.dll')) -and (Test-Path (Join-Path $LinkNative 'libwebrtc.dll')))) {
        & (Join-Path $root 'src\TerminalDeck.Link.Native\build.ps1') -Out $LinkNative
      }
    }
    foreach ($dll in 'tdlink.dll', 'libwebrtc.dll') {
      if (-not (Test-Path (Join-Path $LinkNative $dll))) { throw "$dll is missing in $LinkNative." }
    }
    $linkTests = @(Get-ChildItem -Path (Join-Path $root 'src\TerminalDeck.Platform.Windows\Tests') -Recurse -Filter 'TerminalDeck.Windows.Tests.dll' |
      Where-Object { $_.FullName -match "\\bin\\$Configuration\\" })
    foreach ($dll in $linkTests) { Copy-Item (Join-Path $LinkNative 'tdlink.dll'), (Join-Path $LinkNative 'libwebrtc.dll') -Destination $dll.DirectoryName -Force }
    Note "Direct-link engine from $LinkNative copied next to $($linkTests.Count) test build(s)"
  }

  # 4. Tests: every project that references the test SDK. Proof projects are separate programs, not run here.
  $testProjects = $all | Where-Object { (Get-Content $_ -Raw) -match 'Microsoft\.NET\.Test\.Sdk' }
  $gate = if ($RealPc) { 'Group=RealPc' } else { 'Group!=RealPc&Group!=Unix' }
  if ($CloudOnly) { $gate = 'FullyQualifiedName~TerminalDeck.Core.Tests.Cloud' }
  $named = @{ RealPc = @(); Unix = @() }
  foreach ($project in $testProjects) {
    if ($failedBuilds -contains $project) { Note "TEST SKIP   $project (did not build)"; continue }
    $name = [IO.Path]::GetFileNameWithoutExtension($project)
    $trx = Join-Path $out "$name.trx"; Remove-Item $trx -ErrorAction SilentlyContinue
    & dotnet test $project -c $Configuration --no-build -nologo --filter $gate --logger "trx;LogFileName=$name.trx" --results-directory $out
    $ran = Results $trx
    if ($LASTEXITCODE -ne 0) { $failedTests += $project; Note "TEST FAIL   $project" }
    elseif ($ran.Count -eq 0) { Note "TEST NONE   $project (no test in this group)" }
    else { Note "TEST OK     $project ($($ran.Count) tests)" }
    if ($CloudOnly) { continue }
    # The named groups are run too (never silently left out): their names and results are listed below.
    foreach ($group in @('RealPc', 'Unix')) {
      if ($RealPc -and $group -eq 'RealPc') { $named[$group] += $ran; continue }
      $groupTrx = Join-Path $out "$name.$group.trx"; Remove-Item $groupTrx -ErrorAction SilentlyContinue
      & dotnet test $project -c $Configuration --no-build -nologo --filter "Group=$group" --logger "trx;LogFileName=$name.$group.trx" --results-directory $out | Out-Null
      $named[$group] += Results $groupTrx
    }
  }

  # 5. The golden vectors on their own line: the Windows code must make the Mac's exact bytes.
  # (Only where the Cloud code is present: the golden-vector tests arrive with it.)
  $hasVectors = @(Get-ChildItem 'tests\TerminalDeck.Core.Tests' -Recurse -Filter 'CloudGoldenVectorTests.cs' -ErrorAction SilentlyContinue).Count -gt 0
  if (-not $hasVectors) { Note 'VECTORS SKIP (no Cloud golden-vector tests in this source)' }
  elseif ($failedBuilds -notcontains 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj') {
    & dotnet test 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj' -c $Configuration --no-build -nologo `
      --filter 'FullyQualifiedName~CloudGoldenVectorTests|FullyQualifiedName~CloudMemoryW3Tests' --logger 'trx;LogFileName=golden.trx' --results-directory $out
    if ($LASTEXITCODE -ne 0) { $failedTests += 'golden vectors'; Note 'VECTORS FAIL' } else { Note 'VECTORS OK (43 Mac golden vectors + Swift memory records)' }
  }

  # 6. The named groups, by name and count.
  if (-not $CloudOnly) {
    $why = @{
      RealPc = 'need a real PC with Claude Code, Codex and Gemini installed (run them there: build-and-test.ps1 -RealPc)'
      Unix   = 'check the Linux server helper script with /bin/sh and run on Mac and Linux'
    }
    foreach ($group in @('RealPc', 'Unix')) {
      $rows = @($named[$group])
      Note ''
      Note ("{0} tests {1}:" -f $rows.Count, $why[$group])
      foreach ($row in $rows | Sort-Object Name) { Note ("  {0,-8} {1}" -f $row.Outcome, $row.Name) }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
      Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "### Windows tests in named groups`n"
      foreach ($group in @('RealPc', 'Unix')) {
        $rows = @($named[$group])
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ("**{0} tests {1}** (result on this machine in brackets)`n" -f $rows.Count, $why[$group])
        foreach ($row in $rows | Sort-Object Name) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ("- ``{0}`` ({1})" -f $row.Name, $row.Outcome) }
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ''
      }
    }
  }
}
finally { Pop-Location }

Note ''
Note ("Builds failed: {0}; test runs failed: {1}" -f $failedBuilds.Count, $failedTests.Count)
Note "Summary: $summary"
if ($failedBuilds.Count -gt 0 -or $failedTests.Count -gt 0) { exit 1 }
exit 0
