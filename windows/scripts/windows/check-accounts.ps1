<#
  Focused account/usage/launch/chat/Hoot release gate. Windows only; no app launch,
  installation, RealPc/Unix groups, global vectors or unfiltered test run.
  Builds the shipped App (including keeper/helpers by reference), then five test
  projects. Each test project is invoked exactly once. Does not retry failures.
  -ScratchRoot defaults to RUNNER_TEMP\TD-test or TEMP\TD-test. A private PC can
  explicitly use -ScratchRoot C:\TD-test; never uses the working install/data.
  -LinkNative is optional here; the release workflow supplies the packaged DLLs.
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release',
  [ValidateSet('x64', 'ARM64')] [string] $Platform = 'x64',
  [string] $ScratchRoot = '',
  [string] $LinkNative = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'The accounts release check must run on Windows.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ScratchRoot) {
  $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
  $ScratchRoot = Join-Path $base 'TD-test'
}
if (-not [IO.Path]::IsPathFullyQualified($ScratchRoot)) { throw 'ScratchRoot must be an absolute scratch path.' }
$run = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$scratch = Join-Path $ScratchRoot $run
$out = Join-Path $root ".artifacts\windows-check\accounts\$run"
New-Item -ItemType Directory -Force -Path $scratch, $out | Out-Null
$summary = Join-Path $out 'summary.txt'
$receipt = [ordered]@{ mode = 'accounts'; startedAt = (Get-Date -Format o); configuration = $Configuration; platform = $Platform; scratch = $scratch; sourceCommit = ''; builds = @(); tests = @(); outcome = 'running' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$PSNativeCommandUseErrorActionPreference = $false
function Note([string] $line) { Write-Host $line; Add-Content -LiteralPath $summary -Value $line }
function Invoke-Dotnet([string[]] $Arguments, [string] $Log, [switch] $AllowFailure) {
  & dotnet @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $out $Log) | Out-Host
  if ($AllowFailure) { return $LASTEXITCODE }
  if ($LASTEXITCODE -ne 0) { throw "dotnet failed ($LASTEXITCODE): $($Arguments -join ' ')" }
}
function Selection([string[]] $Names) {
  '(' + (($Names | ForEach-Object { "FullyQualifiedName~$_" }) -join '|') + ')&Group!=RealPc&Group!=Unix'
}
# Explicit allowlists: adding another test project or class never broadens this gate.
$checks = @(
  @{ Project = 'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj'; Names = @(
    'TerminalDeck.Core.Tests.Accounts.', 'TerminalDeck.Core.Tests.Usage.',
    'TerminalDeck.Core.Tests.Integration.W4bAccountTests',
    'TerminalDeck.Core.Tests.Settings.LaunchPermissionDefaultsTests', 'TerminalDeck.Core.Tests.Settings.W14GeneralSettingsTests', 'TerminalDeck.Core.Tests.Settings.PreferenceDefaultsTests',
    'TerminalDeck.Core.Tests.Chats.ChatSessionsTests', 'TerminalDeck.Core.Tests.Chats.ChatRecoveryTests',
    'TerminalDeck.Core.Tests.Chats.ChatStopRenewalTests', 'TerminalDeck.Core.Tests.Chats.ReviewPermissionTests',
    'TerminalDeck.Core.Tests.Chats.ChatMcpTests', 'TerminalDeck.Core.Tests.Chats.W12ChatTests') },
  @{ Project = 'tests\Hoot\TerminalDeck.Hoot.Tests.csproj'; Names = @(
    'TerminalDeck.Hoot.Tests.HootTests', 'TerminalDeck.Hoot.Tests.HootPermissionTests',
    'TerminalDeck.Hoot.Tests.HootRecoverySelectionTests', 'TerminalDeck.Hoot.Tests.HootReadyTests') },
  @{ Project = 'tests\TerminalDeck.Chat.ViewModel.Tests\TerminalDeck.Chat.ViewModel.Tests.csproj'; Names = @(
    'TerminalDeck.Chat.ViewModel.Tests.ChatViewModelTests', 'TerminalDeck.Chat.ViewModel.Tests.IdleSendTests') },
  @{ Project = 'src\TerminalDeck.Platform.Windows\Tests\TerminalDeck.Windows.Tests.csproj'; Names = @(
    'TerminalDeck.Platform.Windows.Tests.WindowsApiLaunchParityTests', 'TerminalDeck.Platform.Windows.Tests.V3cAccountPipeTests',
    'TerminalDeck.Platform.Windows.Tests.V3cModelTests.CodexCapacitiesUseOnlyTheSelectedHomesMatchingModel',
    'TerminalDeck.Platform.Windows.Tests.V3cModelTests.StartupListsKeepExactSelectableIdsAndOnlyReportedLongContext',
    'TerminalDeck.Platform.Windows.Tests.V3cModelTests.UnusableCataloguesAreRefused') },
  @{ Project = 'src\TerminalDeck.App\Views\Windows\Tests\TerminalDeck.Shell.Tests.csproj'; Names = @(
    'TerminalDeck.App.Shell.SessionDraftTests', 'TerminalDeck.App.Shell.WorkspaceTextTests') }
)
$priorTemp = $env:TEMP; $priorTmp = $env:TMP
$priorHoot = $env:TD_HOOT_TEST_ROOT; $priorChat = $env:TD_CHAT_PROOF_ROOT
Push-Location $root
try {
  $receipt.sourceCommit = (& git rev-parse HEAD).Trim()
  Note "Accounts check $($receipt.startedAt); commit=$($receipt.sourceCommit); configuration=$Configuration; platform=$Platform"
  Note "Scratch $scratch; receipts $out"
  $env:TEMP = $scratch; $env:TMP = $scratch
  $env:TD_HOOT_TEST_ROOT = Join-Path $scratch 'hoot'; $env:TD_CHAT_PROOF_ROOT = Join-Path $scratch 'chat'
  New-Item -ItemType Directory -Force -Path $env:TD_HOOT_TEST_ROOT, $env:TD_CHAT_PROOF_ROOT | Out-Null
  $projects = @('src\TerminalDeck.App\TerminalDeck.App.csproj') + @($checks | ForEach-Object { $_.Project })
  foreach ($project in $projects) {
    $name = [IO.Path]::GetFileNameWithoutExtension($project)
    $arguments = @('build', $project, '-c', $Configuration, "-p:Platform=$Platform", '-nologo', '-v', 'minimal')
    if ($LinkNative) { $arguments += "-p:TdLinkNative=$LinkNative" }
    Invoke-Dotnet $arguments "$name.build.log"
    $receipt.builds += [ordered]@{ project = $project; outcome = 'passed' }
    Note "BUILD OK $project"
  }
  foreach ($check in $checks) {
    $project = $check.Project; $name = [IO.Path]::GetFileNameWithoutExtension($project)
    $filter = Selection $check.Names
    Note "FILTER $project $filter"
    $arguments = @('test', $project, '-c', $Configuration, "-p:Platform=$Platform", '--no-build', '--no-restore', '-nologo', '--filter', $filter,
      '--logger', "trx;LogFileName=$name.trx", '--results-directory', $out, '--', 'xUnit.ParallelizeTestCollections=false')
    $testExit = Invoke-Dotnet $arguments "$name.test.log" -AllowFailure
    $trx = Join-Path $out "$name.trx"
    if (-not (Test-Path -LiteralPath $trx)) { throw "No result receipt for $project." }
    $xml = [xml](Get-Content -Raw -LiteralPath $trx)
    $results = @($xml.GetElementsByTagName('UnitTestResult'))
    if ($results.Count -eq 0) { throw "The focused filter selected zero tests in $project." }
    $passed = @($results | Where-Object { $_.outcome -eq 'Passed' }).Count
    $failed = @($results | Where-Object { $_.outcome -eq 'Failed' }).Count
    $other = $results.Count - $passed - $failed
    $receipt.tests += [ordered]@{ project = $project; filter = $filter; total = $results.Count; passed = $passed; failed = $failed; skippedOrOther = $other; trx = $trx }
    Note "TEST $project total=$($results.Count) passed=$passed failed=$failed skipped/other=$other"
    if ($testExit -ne 0 -or $failed -gt 0 -or $passed -eq 0) { throw "Focused tests did not pass in $project." }
  }
  $receipt.outcome = 'passed'
  Note "PASS: $($checks.Count) focused test-project invocations; no RealPc, Unix, global vectors or whole-suite invocation."
}
catch {
  $receipt.outcome = 'failed'
  Note "FAIL $($_.Exception.Message)"
  throw
}
finally {
  $receipt['finishedAt'] = Get-Date -Format o
  $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'receipt.json')
  $env:TEMP = $priorTemp; $env:TMP = $priorTmp
  $env:TD_HOOT_TEST_ROOT = $priorHoot; $env:TD_CHAT_PROOF_ROOT = $priorChat
  Pop-Location
  Write-Host "Receipts: $out"
}
