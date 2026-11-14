<#
  Builds every project of the Windows app and runs every test project, on a Windows machine.
  Nothing is installed, signed, published or pushed; the app is not started.

  Run from any folder (PowerShell 7 or Windows PowerShell 5.1):
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\windows\build-and-test.ps1
  Options:
    -Configuration Release     (default Debug)
    -Platform ARM64            (default x64; used for the WinUI app and its proofs)
    -CloudOnly                 build Core + Core.Tests and run only the Cloud tests (fast check)

  Needs: the .NET SDK named in global.json (10.0.4xx) and, for the WinUI projects, Visual Studio 2022+ or the
  Build Tools with the "Windows application development" workload (Windows App SDK / XAML compiler, Windows SDK
  10.0.19041+). Results land in .artifacts\windows-check\ (one .trx per test project and summary.txt).
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Debug',
  [ValidateSet('x64', 'ARM64')] [string] $Platform = 'x64',
  [switch] $CloudOnly
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

# 1. The SDK global.json asks for.
$wanted = (Get-Content (Join-Path $root 'global.json') -Raw | ConvertFrom-Json).sdk.version
$have = (& dotnet --version) 2>$null
if (-not $have) { throw "No .NET SDK found. Install the .NET SDK $wanted (https://dotnet.microsoft.com/download/dotnet/10.0)." }
$w = $wanted -split '\.'; $h = ($have -split '-')[0] -split '\.'
$sameBand = $w[0] -eq $h[0] -and $w[1] -eq $h[1] -and [math]::Floor([int]$w[2] / 100) -eq [math]::Floor([int]$h[2] / 100) -and [int]$h[2] -ge [int]$w[2]
if (-not $sameBand) { throw "global.json wants SDK $wanted (or a later patch of the same band); this machine has $have." }
Note "SDK $have (global.json $wanted)"

# 2. Which projects. Plain .NET (net10.0) and Windows-only (net10.0-windows); WinUI ones need -p:Platform.
Push-Location $root
try {
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

  # 3. Tests: every project that references the test SDK. Proof projects are separate programs, not run here.
  $testProjects = $all | Where-Object { (Get-Content $_ -Raw) -match 'Microsoft\.NET\.Test\.Sdk' }
  foreach ($project in $testProjects) {
    if ($failedBuilds -contains $project) { Note "TEST SKIP   $project (did not build)"; continue }
    $name = [IO.Path]::GetFileNameWithoutExtension($project)
    $cmd = @('test', $project, '-c', $Configuration, '--no-build', '-nologo', '--logger', "trx;LogFileName=$name.trx", '--results-directory', $out)
    if ($CloudOnly) { $cmd += @('--filter', 'FullyQualifiedName~TerminalDeck.Core.Tests.Cloud') }
    & dotnet @cmd
    if ($LASTEXITCODE -ne 0) { $failedTests += $project; Note "TEST FAIL   $project" } else { Note "TEST OK     $project" }
  }

  # 4. The golden vectors on their own line: the Windows code must make the Mac's exact bytes.
  # (Only where the Cloud code is present: the golden-vector tests arrive with it.)
  $hasVectors = @(Get-ChildItem 'tests\TerminalDeck.Core.Tests' -Recurse -Filter 'CloudGoldenVectorTests.cs' -ErrorAction SilentlyContinue).Count -gt 0
  if (-not $hasVectors) { Note 'VECTORS SKIP (no Cloud golden-vector tests in this source)' }
  elseif ($failedBuilds -notcontains 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj') {
    & dotnet test 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj' -c $Configuration --no-build -nologo `
      --filter 'FullyQualifiedName~CloudGoldenVectorTests|FullyQualifiedName~CloudMemoryW3Tests' --logger 'trx;LogFileName=golden.trx' --results-directory $out
    if ($LASTEXITCODE -ne 0) { $failedTests += 'golden vectors'; Note 'VECTORS FAIL' } else { Note 'VECTORS OK (43 Mac golden vectors + Swift memory records)' }
  }
}
finally { Pop-Location }

Note ''
Note ("Builds failed: {0}; test runs failed: {1}" -f $failedBuilds.Count, $failedTests.Count)
Note "Summary: $summary"
if ($failedBuilds.Count -gt 0 -or $failedTests.Count -gt 0) { exit 1 }
exit 0
