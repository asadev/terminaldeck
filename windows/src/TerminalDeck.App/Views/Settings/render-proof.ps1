param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Run,[string]$PriorWindowsTestResult='')
if($PriorWindowsTestResult -and $PriorWindowsTestResult -notmatch '^C:\\TD\\out\\[a-zA-Z0-9_-]+\\windows-tests\.json$'){throw 'Use an owned prior Windows test result'}
$ErrorActionPreference='Stop'
if(-not $Source.StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase) -or $Run -notmatch '^[0-9]{8}T[0-9]{6}Z-settings[a-z0-9-]*$'){throw 'Use isolated Settings paths'}
$data="C:\TD-SettingsProof\$Run"
$out="C:\TD\out\$Run"
if((Test-Path $data) -or (Test-Path $out)){throw 'Use a new proof run; data or output already exists'}
New-Item -ItemType Directory -Force "$data\proof",$out | Out-Null
$env:TEMP=$data; $env:TMP=$data; $env:TD_SETTINGS_PROOF="$data\proof"
$exe=Join-Path $Source 'src\TerminalDeck.App\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.App.exe'
$app=$null; $forcedStop=$false
try {
if($PriorWindowsTestResult){
  $prior=Get-Content $PriorWindowsTestResult -Raw | ConvertFrom-Json
  [xml]$trx=Get-Content (Join-Path (Split-Path $PriorWindowsTestResult) 'windows.trx') -Raw
  $counts=$trx.SelectSingleNode("//*[local-name()='Counters']")
  if(!$prior.ok -or $prior.exitCode -ne 0 -or $prior.desktopSession -ne 1 -or [int]$counts.passed -ne 4 -or [int]$counts.failed -ne 0){throw 'Prior Windows tests did not pass'}
  @{checkedAt=(Get-Date).ToUniversalTime().ToString('o');passedEarlier=$true;ranThisTime=$false;passed=4;failed=0;source=$PriorWindowsTestResult;sourceSha256=(Get-FileHash $PriorWindowsTestResult -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content "$out\windows-tests-reused.json"
}else{
# Credential Manager belongs to the interactive user's logon session.
# SSH may share the SID but cannot open that session's credential store.
. C:\TD\setup\env.ps1
Set-Location $Source
$ErrorActionPreference='Continue'
& dotnet test src/TerminalDeck.Platform.Windows/Tests/TerminalDeck.Windows.Tests.csproj -c Release -p:Platform=x64 --no-build --no-restore --filter 'FullyQualifiedName~W12InstallationTests|FullyQualifiedName~W12McpSecretTests' --logger 'trx;LogFileName=windows.trx' --results-directory $out *> "$out\windows-tests.log"
$testCode=$LASTEXITCODE
$ErrorActionPreference='Stop'
@{at=(Get-Date).ToUniversalTime().ToString('o');ok=($testCode -eq 0);exitCode=$testCode;desktopSession=(Get-Process -Id $PID).SessionId} | ConvertTo-Json | Set-Content "$out\windows-tests.json"
if($testCode){throw 'Windows focused tests failed; inspect windows-tests.log'}
}
  $app=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList @('--user-data-dir',$data) -WindowStyle Minimized -PassThru
  $identity=$app.StartTime.ToUniversalTime()
  $until=(Get-Date).AddSeconds(90)
  while(-not (Test-Path "$data\proof\result.json")){
    $app.Refresh()
    if($app.HasExited){throw 'Settings proof exited before writing its result'}
    if((Get-Date) -gt $until){throw 'Settings proof timed out'}
    Start-Sleep -Milliseconds 300
  }
  Copy-Item "$data\proof\*" $out
} catch {@{ok=$false;message=$_.Exception.Message} | ConvertTo-Json | Set-Content "$out\render-error.json"}
finally {
  if($app){
    $app.Refresh()
    if(-not $app.HasExited -and $app.StartTime.ToUniversalTime() -eq $identity -and $app.Path -eq $exe){
      $app.CloseMainWindow() | Out-Null
      if(-not $app.WaitForExit(5000)){$forcedStop=$true; Stop-Process -Id $app.Id}
    }
  }
  # The supervisor deliberately survives windows. Cleanup proves this root is empty,
  # pins its exact process identity, then removes only this test's credentials.
  try { & (Join-Path $Source 'src\TerminalDeck.App\Views\Settings\w12-cleanup.ps1') -Run $Run }
  catch { @{at=(Get-Date).ToUniversalTime().ToString('o');message=$_.Exception.Message} | ConvertTo-Json | Set-Content "$out\owned-cleanup-error.json" }
  @{at=(Get-Date).ToUniversalTime().ToString('o');forcedOwnedAppStop=$forcedStop;ownedApps=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe}).Count;root=$data} | ConvertTo-Json | Set-Content "$out\cleanup.json"
}
