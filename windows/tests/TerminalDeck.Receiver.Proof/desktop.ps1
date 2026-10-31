param([Parameter(Mandatory=$true)][string]$Checkout,[Parameter(Mandatory=$true)][string]$Out,
      [string]$CaptureSource='', [switch]$ReclaimOnly)
$ErrorActionPreference='Stop'
if(!$Checkout.StartsWith('C:\TD\work\') -or !$Out.StartsWith('C:\TD\out\')) { throw 'Use isolated paths under C:\TD' }
$env:TEMP="$Out\temp"; $env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$exe=Join-Path $Checkout 'tests\TerminalDeck.Receiver.Proof\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64\TerminalDeck.Receiver.Proof.exe'
$app=$null
try {
 if($CaptureSource) {
  if(!$CaptureSource.StartsWith('C:\TD\out\')){throw 'Capture source must be this lane''s saved preview data.'}
  $env:TD_RECEIVER_CAPTURE_SOURCE=$CaptureSource
 }
 if($ReclaimOnly){$env:TD_RECEIVER_RECLAIM_PROOF='1'}
 if(Test-Path "$Out\result.json") { throw 'Proof output already exists; refusing to overwrite it.' }
 $app=Start-Process $exe -ArgumentList "--user-data-dir=$Out\scratch" -WorkingDirectory (Split-Path $exe) -PassThru
 $started=$app.StartTime
 $app.PriorityClass='BelowNormal'
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ReceiverCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd,int attr,out RECT rect,int size);
}
'@
 [ReceiverCapture]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
 Add-Type -AssemblyName System.Drawing
 $end=(Get-Date).AddMinutes(4); $frames=@{}
 while(!(Test-Path "$Out\result.json")) {
  if((Get-Date) -gt $end){throw 'Receiver proof timed out.'}
  $app.Refresh(); if($app.HasExited){throw 'Receiver proof exited before reporting.'}
  if(Test-Path "$Out\stage.json") {
   try {$stage=Get-Content "$Out\stage.json" -Raw | ConvertFrom-Json} catch {Start-Sleep -Milliseconds 100; continue}
   $name=$stage.name
   if($name -and !$frames.ContainsKey($name)) {
    $hwnd=$app.MainWindowHandle
    [ReceiverCapture]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 250
    if([ReceiverCapture]::GetForegroundWindow() -ne $hwnd){throw 'Preview is not in front; refusing to capture another app.'}
    $rect=New-Object ReceiverCapture+RECT
    if([ReceiverCapture]::DwmGetWindowAttribute($hwnd,9,[ref]$rect,16) -ne 0){throw 'Could not read the owned window bounds.'}
    $bitmap=New-Object System.Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $bitmap.Save("$Out\$name.png",[System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose(); $frames[$name]=$true
    New-Item -ItemType File "$Out\$name.ack" | Out-Null
   }
  }
  Start-Sleep -Milliseconds 100
 }
 @{ok=$true;processId=$app.Id;appSession=$app.SessionId;frames=$frames.Count;at=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content "$Out\desktop.json"
} catch {
 @{ok=$false;message=$_.Exception.Message;at=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content "$Out\desktop.json"
} finally {
 if($app) {
  $app.Refresh()
  if(!$app.HasExited -and $app.StartTime -eq $started -and $app.Path -eq $exe) { $app.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 300; $app.Refresh(); if(!$app.HasExited){Stop-Process -Id $app.Id} }
 }
}
