param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Run,[switch]$Desktop)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-servers$' -or ![IO.Path]::GetFullPath($Source).StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use this lane checkout and scratch run'}
$out="C:\TD\out\$Run";$status="$out\credential-retry.json"
if(!$Desktop){
 if(Test-Path $status){throw 'This failed-check retry already ran; do not repeat it'}
 $initial=Get-Item "$out\windows-tests.log"
 if([DateTime]::UtcNow -lt $initial.LastWriteTimeUtc.AddMinutes(10)){throw 'Wait ten minutes after the first credential checks'}
 $task="TD-Servers-Credentials-$Run"
 if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'Proof task already exists'}
 $script=Join-Path $Source 'tests\TerminalDeck.Servers.Proof\credential-retry.ps1'
 $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Source `"$Source`" -Run $Run -Desktop" -WorkingDirectory $out
 $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
 try{
  Register-ScheduledTask -TaskName $task -Action $action -Principal $principal|Out-Null;Start-ScheduledTask -TaskName $task
  $until=(Get-Date).AddMinutes(2)
  while(!(Test-Path $status) -and (Get-Date) -lt $until){Start-Sleep -Milliseconds 300}
  if(!(Test-Path $status)){throw 'Interactive credential check did not finish'}
  Get-Content $status
 }finally{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue}
 exit 0
}
$code=1
try{
 . C:\TD\setup\env.ps1
 $env:TEMP="$out\temp";$env:TMP=$env:TEMP;$env:TD_SERVERS_PROOF_ROOT=$out
 $env:TD_SERVERS_ASKPASS=Join-Path $Source 'tests\TerminalDeck.Servers.Askpass\bin\x64\Release\net10.0\TerminalDeck.Servers.Askpass.exe'
 Set-Location $Source;(Get-Process -Id $PID).PriorityClass='BelowNormal'
 $filter='FullyQualifiedName~CredentialManagerRoundTripAndNamespaceIsolation|FullyQualifiedName~PasswordHelperRunsAsRealChildWithoutSecretArgumentsOrEnvironment'
 $ErrorActionPreference='Continue'
 & dotnet test tests/TerminalDeck.Servers.Windows.Tests/TerminalDeck.Servers.Windows.Tests.csproj --no-restore --no-build -c Release -p:Platform=x64 -m:2 --filter $filter --logger 'trx;LogFileName=servers-windows-interactive.trx' --results-directory $out *> "$out\credential-retry.log"
 $code=$LASTEXITCODE
}finally{
 @{exitCode=$code;utc=(Get-Date).ToUniversalTime().ToString('o');interactiveSession=(Get-Process -Id $PID).SessionId;onlyInitiallyFailedTests=$true}|ConvertTo-Json|Set-Content $status
}
