param([string]$Source='C:\TD\work\w12-settings-accounts',[string]$Output='C:\TD\out\w12-settings-accounts\final')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
if($Source -cne 'C:\TD\work\w12-settings-accounts' -or !$Output.StartsWith('C:\TD\out\w12-settings-accounts\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use this lane isolated paths'}
New-Item -ItemType Directory -Force $Output | Out-Null
. C:\TD\setup\env.ps1
(Get-Process -Id $PID).PriorityClass='BelowNormal'
$locked=$false
try {
  $until=(Get-Date).AddMinutes(20)
  while(!$locked){
    try {New-Item -ItemType Directory C:\TD\locks\build -ErrorAction Stop | Out-Null; $locked=$true}
    catch {if((Get-Date) -ge $until){throw 'PC build lock stayed busy for 20 minutes'}; Start-Sleep -Seconds 5}
  }
  @{lane='w12-settings-accounts';at=(Get-Date).ToUniversalTime().ToString('o');pid=$PID} | ConvertTo-Json | Set-Content C:\TD\locks\build\owner.json
  Set-Location $Source
  & dotnet build src/TerminalDeck.App/TerminalDeck.App.csproj -t:Rebuild -c Release -p:Platform=x64 -m:1 -nr:false -p:UseSharedCompilation=false *> "$Output\build.log"
  $code=$LASTEXITCODE
  @{at=(Get-Date).ToUniversalTime().ToString('o');ok=($code -eq 0);exitCode=$code;source=$Source;archiveSha256=(Get-FileHash C:\TD\w12-settings-source.tar.gz -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content "$Output\build.json"
  if($code){Get-Content "$Output\build.log" -Tail 25; exit $code}
  & dotnet build src/TerminalDeck.Platform.Windows/Tests/TerminalDeck.Windows.Tests.csproj -c Release -p:Platform=x64 -m:1 -nr:false -p:UseSharedCompilation=false *> "$Output\windows-tests-build.log"
  $code=$LASTEXITCODE
  @{at=(Get-Date).ToUniversalTime().ToString('o');ok=($code -eq 0);exitCode=$code;note='Credential-store tests run in the isolated interactive proof, not the SSH logon'} | ConvertTo-Json | Set-Content "$Output\windows-tests-build.json"
  Get-Content "$Output\build.log" -Tail 7
  Get-Content "$Output\windows-tests-build.log" -Tail 8
  exit $code
} finally {if($locked){Remove-Item C:\TD\locks\build\owner.json -ErrorAction SilentlyContinue; Remove-Item C:\TD\locks\build}}
