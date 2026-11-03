param([ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Run,[ValidateSet('create','restart','recovery','settings','delta','cleanup','inspect','w4b','browser-read','account-add')][string]$Phase,[ValidatePattern('^C:\\TD\\work\\[A-Za-z0-9._-]+$')][string]$Checkout='C:\TD\work\win-integrate')
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\TD\w4-desktop.ps1 -Run $Run -Phase $Phase -Checkout $Checkout"
$principal=New-ScheduledTaskPrincipal -UserId 'sm' -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName "TD-W4-$Run-$Phase" -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName "TD-W4-$Run-$Phase"
