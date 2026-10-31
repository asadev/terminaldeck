param([Parameter(Mandatory=$true)][string]$Work, [Parameter(Mandatory=$true)][string]$Out, [switch]$Desktop, [switch]$Details, [switch]$BoardOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Work=[IO.Path]::GetFullPath($Work)
$Out=[IO.Path]::GetFullPath($Out)
if ($Work -notmatch '^C:\\TD\\work\\[a-f0-9]{64}$' -or $Out -notmatch '^C:\\TD\\out\\win-hoot-[a-zA-Z0-9-]+$') { throw 'Use this lane checkout and an isolated proof root under C:\TD.' }
. C:\TD\setup\env.ps1
New-Item -ItemType Directory -Force "$Out\temp","$Out\render" | Out-Null
$env:TEMP="$Out\temp"; $env:TMP=$env:TEMP
if ($Desktop) {
  if ($Details) { $env:TD_HOOT_DETAILS_ONLY='1' }
  if ($BoardOnly) { $env:TD_HOOT_BOARD_ONLY='1' }
  $exe=Join-Path $Work 'tests\HootProof\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.Hoot.Proof.exe'
  $app=Start-Process $exe -ArgumentList "--user-data-dir $Out\render" -WorkingDirectory (Split-Path $exe) -PassThru
  $app.PriorityClass='BelowNormal'
  @{pid=$app.Id; started=$app.StartTime.ToUniversalTime().ToString('o'); exe=$exe; session=$app.SessionId} | ConvertTo-Json | Set-Content "$Out\proof-process.json"
  if ($app.SessionId -eq 0) { throw 'The proof needs an interactive desktop session.' }
  if (!$app.WaitForExit(55000)) {
    $app.Refresh()
    if ($app.Path -eq $exe) { $app.Kill(); $app.WaitForExit() }
    throw 'The isolated Hoot render check timed out.'
  }
  if (!(Test-Path "$Out\render\proof.json")) { throw 'The isolated Hoot render check did not finish. Inspect proof-failed.json.' }
  exit
}
$task='TD-Hoot-Proof-'+(Get-Date -Format 'yyyyMMddHHmmss')
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'Proof task already exists.' }
$detailsFlag=if ($BoardOnly) { ' -BoardOnly' } elseif ($Details) { ' -Details' } else { '' }
$arguments="-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Work $Work -Out $Out -Desktop$detailsFlag"
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $Out
try {
  Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
  Start-ScheduledTask -TaskName $task
  $deadline=(Get-Date).AddSeconds(60)
  do { Start-Sleep -Milliseconds 500; $info=Get-ScheduledTaskInfo -TaskName $task; $status=Get-ScheduledTask -TaskName $task } while ($status.State -eq 'Running' -and (Get-Date) -lt $deadline)
  if ($info.LastTaskResult -ne 0 -or !(Test-Path "$Out\render\proof.json")) { throw 'The isolated render task failed. Inspect the lane proof files.' }
  Get-Content "$Out\render\proof.json"
} finally {
  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
