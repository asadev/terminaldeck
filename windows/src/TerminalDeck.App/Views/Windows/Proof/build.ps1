param([string]$Checkout='C:\TD\work\92c47c15948720acca8af53dbc2478442139e2b50b1d50d2fa72b6790e5d66cd', [string]$Out='C:\TD\out\p-shell')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if (!$Checkout.StartsWith('C:\TD\work\') -or !$Out.StartsWith('C:\TD\out\')) { throw 'Use an isolated checkout and evidence directory.' }
New-Item -ItemType Directory -Force $Out | Out-Null
$held=$false
$started=(Get-Date).ToUniversalTime().ToString('o')
$ok=$false
try {
  $deadline=(Get-Date).AddMinutes(15)
  while (!$held) {
    try {
      New-Item -ItemType Directory 'C:\TD\locks\build' -ErrorAction Stop | Out-Null
      $held=$true
      Set-Content 'C:\TD\locks\build\owner.txt' "p-shell $PID"
    } catch {
      if ((Get-Date) -gt $deadline) { throw 'Shared build lock was not available within 15 minutes.' }
      Start-Sleep -Seconds 5
    }
  }
  . C:\TD\setup\env.ps1
  (Get-Process -Id $PID).PriorityClass='BelowNormal'
  Set-Location $Checkout
  & dotnet build src/TerminalDeck.App/TerminalDeck.App.csproj -c Release -p:Platform=x64 -m:2 *> "$Out\build.log"
  if ($LASTEXITCODE) { throw "Windows app build failed: $LASTEXITCODE" }
  & dotnet test src/TerminalDeck.App/Views/Windows/Tests/TerminalDeck.Shell.Tests.csproj --artifacts-path "$Out\test-artifacts" -m:2 --logger "trx;LogFileName=shell.trx" --results-directory $Out *> "$Out\tests.log"
  if ($LASTEXITCODE) { throw "Workspace tests failed: $LASTEXITCODE" }
  $ok=$true
} catch { $reason=$_.Exception.Message; throw }
finally {
  @{ok=$ok;started=$started;finished=(Get-Date).ToUniversalTime().ToString('o');commit=(& git -C $Checkout rev-parse HEAD);reason=$reason} | ConvertTo-Json | Set-Content "$Out\build-result.json"
  if ($held) { Remove-Item 'C:\TD\locks\build' -Recurse }
}
