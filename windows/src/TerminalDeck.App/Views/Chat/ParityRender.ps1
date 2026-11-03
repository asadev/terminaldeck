param([ValidateSet('Build','Render','Schedule')][string]$Mode='Build', [string]$Out='C:\TD\out\p-chat')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$exe=Join-Path $root 'src\TerminalDeck.App\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64\TerminalDeck.App.exe'
New-Item -ItemType Directory -Force $Out | Out-Null
if ($Mode -eq 'Build') {
 . C:\TD\setup\env.ps1
 (Get-Process -Id $PID).PriorityClass='BelowNormal'
 $deadline=(Get-Date).AddMinutes(20)
 while ($true) {
  try { New-Item -ItemType Directory C:\TD\locks\build -ErrorAction Stop | Out-Null; break }
  catch { if ((Get-Date) -gt $deadline) { throw 'Shared build lock timed out' }; Start-Sleep -Seconds 8 }
 }
 try {
  Push-Location $root
  dotnet build src/TerminalDeck.App/TerminalDeck.App.csproj -c Release -p:Platform=x64 -m:2 > "$Out\build-final.log" 2>&1
  if ($LASTEXITCODE) { throw 'Ordinary app build failed; see build-final.log' }
  dotnet build src/TerminalDeck.App/TerminalDeck.App.csproj -c Release -p:Platform=x64 -m:2 '-p:DefineConstants=TD_CHAT_PARITY_RENDER%3BDISABLE_XAML_GENERATED_MAIN' -p:StartupObject=TerminalDeck.App.Views.Chat.ChatParityProgram > "$Out\render-build.log" 2>&1
  if ($LASTEXITCODE) { throw 'Render build failed; see render-build.log' }
  @{ commit=(git rev-parse HEAD); exeHash=(Get-FileHash $exe -Algorithm SHA256).Hash; dllHash=(Get-FileHash ($exe -replace '\.exe$','.dll') -Algorithm SHA256).Hash; at=(Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content "$Out\render-build.json"
 } finally { Pop-Location; Remove-Item C:\TD\locks\build }
 exit
}
if ($Mode -eq 'Render') {
 $marker=Get-Content "$Out\render-build.json" -Raw | ConvertFrom-Json
 if ($marker.exeHash -ne (Get-FileHash $exe -Algorithm SHA256).Hash -or $marker.dllHash -ne (Get-FileHash ($exe -replace '\.exe$','.dll') -Algorithm SHA256).Hash) { throw 'Renderer binary changed since its successful build' }
 $env:TD_CHAT_PARITY_OUT=Join-Path $Out 'renders'
 New-Item -ItemType Directory -Force $env:TD_CHAT_PARITY_OUT | Out-Null
 $p=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList "--user-data-dir=$Out\unused-scratch" -PassThru
 Set-Content "$Out\owned-render-pid.txt" $p.Id
 if (!$p.WaitForExit(90000)) { $p.Kill(); throw 'Only this owned render process timed out' }
 Set-Content "$Out\render-exit.txt" $p.ExitCode
 exit
}
Remove-Item "$Out\renders\result.json" -ErrorAction SilentlyContinue
$task='TD-p-chat-render-'+(Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Render -Out `"$Out`""
$principal=New-ScheduledTaskPrincipal -UserId 'sm' -LogonType Interactive -RunLevel Limited
try {
 Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
 Start-ScheduledTask -TaskName $task
 $deadline=(Get-Date).AddSeconds(100)
 while (!(Test-Path "$Out\renders\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
 if (!(Test-Path "$Out\renders\result.json")) { throw 'No render result; inspect owned task exit and render log' }
 Get-Content "$Out\renders\result.json"
} finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue }
