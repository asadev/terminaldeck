param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Run,[ValidateSet('build','tests','walk')][string]$Mode='build',[switch]$Desktop)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-servers$'){throw 'Use a unique servers proof run'}
$sourcePath=[IO.Path]::GetFullPath($Source)
if(!$sourcePath.StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use an isolated C:\TD\work checkout'}
$out="C:\TD\out\$Run"
New-Item -ItemType Directory -Force "$out\temp" | Out-Null
$env:TEMP="$out\temp"; $env:TMP=$env:TEMP
. C:\TD\setup\env.ps1
(Get-Process -Id $PID).PriorityClass='BelowNormal'
Set-Location $sourcePath
if($Mode -eq 'build'){
 foreach($p in @('src/TerminalDeck.App/TerminalDeck.App.csproj','tests/TerminalDeck.Servers.Proof/TerminalDeck.Servers.Proof.csproj','tests/TerminalDeck.Servers.Askpass/TerminalDeck.Servers.Askpass.csproj','tests/TerminalDeck.Servers.Windows.Tests/TerminalDeck.Servers.Windows.Tests.csproj')){
  $name=[IO.Path]::GetFileNameWithoutExtension($p)
  & dotnet build $p -c Release -p:Platform=x64 -m:2 *> "$out\$name-build.log"
  $code=$LASTEXITCODE
  @{exitCode=$code;utc=(Get-Date).ToUniversalTime().ToString('o');commit=(git rev-parse HEAD)}|ConvertTo-Json|Set-Content "$out\$name-build.json"
  if($code){Get-Content "$out\$name-build.log" -Tail 20; throw "$name failed"}
 }
 exit 0
}
if($Mode -eq 'tests'){
 $env:TD_SERVERS_PROOF_ROOT=$out
 $env:TD_SERVERS_ASKPASS=Join-Path $sourcePath 'tests\TerminalDeck.Servers.Askpass\bin\x64\Release\net10.0\TerminalDeck.Servers.Askpass.exe'
 & dotnet test tests/TerminalDeck.Servers.Windows.Tests/TerminalDeck.Servers.Windows.Tests.csproj --no-build --no-restore -c Release -p:Platform=x64 -m:2 --logger 'trx;LogFileName=servers-windows.trx' --results-directory $out *> "$out\windows-tests.log"
 $code=$LASTEXITCODE
 @{exitCode=$code;utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content "$out\windows-tests.json"
 Get-Content "$out\windows-tests.log" -Tail 15
 exit $code
}
if(!$Desktop){
 $task="TD-Servers-$Run"
 if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){throw 'This proof task already exists'}
 $self=Join-Path $sourcePath 'tests\TerminalDeck.Servers.Proof\run.ps1'
 $args="-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Source `"$sourcePath`" -Run $Run -Mode walk -Desktop"
 $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args -WorkingDirectory $out
 $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
 try{
  Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
  Start-ScheduledTask -TaskName $task
  $until=(Get-Date).AddMinutes(4)
  while(!(Test-Path "$out\walk-status.json") -and (Get-Date) -lt $until){Start-Sleep -Milliseconds 500}
  if(!(Test-Path "$out\walk-status.json")){throw 'Desktop proof timed out'}
  Get-Content "$out\walk-status.json"
 }finally{
  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
 }
 exit 0
}
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ServersFrame {
 [StructLayout(LayoutKind.Sequential)] public struct Box { public int L,T,R,B; }
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out Box b,int n);
}
'@
[ServersFrame]::SetThreadDpiAwarenessContext([IntPtr](-4))|Out-Null
$app=$null; $exe=Join-Path $sourcePath 'tests\TerminalDeck.Servers.Proof\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.Servers.Proof.exe'
$scratch="$out\scratch"; $proof="$scratch\proof"; $frames=@{}; $ok=$false
try{
 if(Test-Path $scratch){throw 'Use a fresh scratch root'}
 New-Item -ItemType Directory -Force $proof|Out-Null
 $app=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList @('--user-data-dir',$scratch) -PassThru
 $identity=$app.StartTime.ToUniversalTime()
 $until=(Get-Date).AddMinutes(3)
 while(!(Test-Path "$proof\result.json")){
  $app.Refresh()
  if($app.HasExited){throw 'Scratch preview exited before completing'}
  if((Get-Date) -gt $until){throw 'Scratch preview timed out'}
  if(Test-Path "$proof\stage.json"){
   $stage=$null;try{$stage=Get-Content "$proof\stage.json" -Raw|ConvertFrom-Json}catch{}
   if($stage -and $stage.name -match '^[0-9]{2}-[a-z-]+$' -and !$frames.ContainsKey($stage.name)){
    if($app.SessionId -eq 0 -or $app.SessionId -ne (Get-Process -Id $PID).SessionId){throw 'Preview is not in this desktop session'}
    $h=$app.MainWindowHandle
    [ServersFrame]::SetForegroundWindow($h)|Out-Null;Start-Sleep -Milliseconds 300
    if([ServersFrame]::GetForegroundWindow() -ne $h){throw 'Preview is not foreground; refusing to capture another window'}
    $box=New-Object ServersFrame+Box
    if([ServersFrame]::DwmGetWindowAttribute($h,9,[ref]$box,16) -ne 0){throw 'Could not read preview frame'}
    $bitmap=New-Object System.Drawing.Bitmap(($box.R-$box.L),($box.B-$box.T));$g=[System.Drawing.Graphics]::FromImage($bitmap)
    try{$g.CopyFromScreen($box.L,$box.T,0,0,$bitmap.Size);$bitmap.Save("$out\$($stage.name).png",[System.Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
    $frames[$stage.name]=$true;New-Item -ItemType File "$proof\$($stage.name).ack"|Out-Null
   }
  }
  Start-Sleep -Milliseconds 100
 }
 Copy-Item "$proof\result.json" "$out\preview-checks.json"
 $result=Get-Content "$out\preview-checks.json" -Raw|ConvertFrom-Json
 $ok=$result.failed -eq 0
} catch {
 @{type=$_.Exception.GetType().Name;code=$_.Exception.HResult.ToString('X8')}|ConvertTo-Json|Set-Content "$out\walk-error.json"
} finally {
 if($app){
  $app.Refresh()
  if(!$app.HasExited -and $app.StartTime.ToUniversalTime() -eq $identity -and $app.Path -eq $exe){
   $app.CloseMainWindow()|Out-Null
   if(!$app.WaitForExit(4000)){Stop-Process -Id $app.Id}
  }
 }
 @{ok=$ok;frames=$frames.Count;utc=(Get-Date).ToUniversalTime().ToString('o');ownedProcessStopped=(!$app -or $app.HasExited)}|ConvertTo-Json|Set-Content "$out\walk-status.json"
}
