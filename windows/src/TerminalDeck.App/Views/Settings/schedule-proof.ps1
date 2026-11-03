param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Run,[string]$PriorWindowsTestResult='')
if($PriorWindowsTestResult -and $PriorWindowsTestResult -notmatch '^C:\\TD\\out\\[a-zA-Z0-9_-]+\\windows-tests\.json$'){throw 'Use an owned prior Windows test result'}
$ErrorActionPreference='Stop'
if(-not $Source.StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase) -or $Run -notmatch '^[0-9]{8}T[0-9]{6}Z-settings[a-z0-9-]*$'){throw 'Use isolated Settings paths'}
$name="TD-Settings-$Run"
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'This proof task already exists'}
$script=Join-Path $Source 'src\TerminalDeck.App\Views\Settings\render-proof.ps1'
$launchArguments="-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Source `"$Source`" -Run $Run"
if($PriorWindowsTestResult){$launchArguments += " -PriorWindowsTestResult `"$PriorWindowsTestResult`""}
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Priority 7
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $launchArguments
try {
  Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
  Start-ScheduledTask -TaskName $name
  $until=(Get-Date).AddSeconds(210)
  while(-not (Test-Path "C:\TD\out\$Run\cleanup.json")){
    if((Get-Date) -gt $until){throw 'Isolated Settings desktop check timed out'}
    Start-Sleep -Milliseconds 500
  }
  if(Test-Path "C:\TD\out\$Run\result.json"){Get-Content "C:\TD\out\$Run\result.json"}
  else {Get-Content "C:\TD\out\$Run\render-error.json"; exit 1}
} finally {
  Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
