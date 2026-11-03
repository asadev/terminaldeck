param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Run)
$ErrorActionPreference='Stop'
if(-not $Source.StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use an isolated source tree'}
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-settings[a-z0-9-]*$'){throw 'Choose a Settings proof run name'}
$out="C:\TD\out\$Run"
New-Item -ItemType Directory -Force $out | Out-Null
. C:\TD\setup\env.ps1
(Get-Process -Id $PID).PriorityClass='BelowNormal'
$env:TEMP="$out\temp"; $env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
Set-Location $Source
& git apply --check src/TerminalDeck.App/Views/Settings/integration.patch 2>$null
if($LASTEXITCODE -eq 0){& git apply src/TerminalDeck.App/Views/Settings/integration.patch}
else {& git apply --reverse --check src/TerminalDeck.App/Views/Settings/integration.patch; if($LASTEXITCODE){throw 'Integration patch does not apply'}}
$locked=$false
$until=(Get-Date).AddMinutes(18)
while(-not $locked){
  try {New-Item -ItemType Directory C:\TD\locks\build -ErrorAction Stop | Out-Null; $locked=$true}
  catch {if((Get-Date) -gt $until){throw 'PC build lock stayed busy'}; Start-Sleep -Seconds 5}
}
try {
  @{lane='p-settings';at=(Get-Date).ToUniversalTime().ToString('o');pid=$PID} | ConvertTo-Json | Set-Content C:\TD\locks\build\owner.json
  & dotnet build src/TerminalDeck.App/TerminalDeck.App.csproj -c Release -p:Platform=x64 -m:2 *> "$out\build.log"
  $code=$LASTEXITCODE
  @{at=(Get-Date).ToUniversalTime().ToString('o');ok=($code -eq 0);exitCode=$code;source=$Source;integrationPatchApplied=$true} | ConvertTo-Json | Set-Content "$out\build.json"
  if($code){Get-Content "$out\build.log" -Tail 45; exit $code}
} finally {if($locked){Remove-Item C:\TD\locks\build\owner.json -ErrorAction SilentlyContinue; Remove-Item C:\TD\locks\build}}
Get-Content "$out\build.log" -Tail 12
