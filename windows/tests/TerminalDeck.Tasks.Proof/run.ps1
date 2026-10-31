param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Run, [string]$Resume='')
$ErrorActionPreference='Stop'
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-tasks(?:-[a-z0-9]+)?$'){throw 'Choose a unique Tasks proof run name'}
if(-not [IO.Path]::GetFullPath($Source).StartsWith('C:\TD\work\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use an isolated checkout under C:\TD\work'}
$data="C:\TD\tasks-proof\$Run"
$out="C:\TD\out\$Run"
if(Test-Path $data){throw 'This proof root already exists'}
New-Item -ItemType Directory -Force $data,$out | Out-Null
$env:TEMP=$data
$env:TMP=$data
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TasksPreviewFrame {
  [StructLayout(LayoutKind.Sequential)] public struct Bounds { public int Left,Top,Right,Bottom; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window,int attribute,out Bounds bounds,int size);
}
'@
[TasksPreviewFrame]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
$app=$null
try {
  $env:TD_TASKS_PROOF_RESUME=$Resume
  $exe=Join-Path $Source 'tests\TerminalDeck.Tasks.Proof\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.Tasks.Proof.exe'
  $app=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList @('--user-data-dir',$data) -PassThru
  $identity=$app.StartTime.ToUniversalTime()
  $captured=@{}
  $until=(Get-Date).AddMinutes(3)
  while(-not (Test-Path "$data\result.json")) {
    $app.Refresh()
    if($app.HasExited){throw 'The isolated Tasks window exited early'}
    if((Get-Date) -gt $until){throw 'The isolated Tasks window timed out'}
    if(Test-Path "$data\stage.json") {
      $stage=$null
      try {$stage=Get-Content "$data\stage.json" -Raw | ConvertFrom-Json} catch {}
      if($stage -and $stage.name -match '^[0-9]{2}-[a-z-]+$' -and -not $captured.ContainsKey($stage.name)) {
        if($app.SessionId -eq 0 -or $app.SessionId -ne (Get-Process -Id $PID).SessionId){throw 'The Tasks window is outside this interactive desktop'}
        $window=$app.MainWindowHandle
        [TasksPreviewFrame]::SetForegroundWindow($window) | Out-Null
        Start-Sleep -Milliseconds 250
        if([TasksPreviewFrame]::GetForegroundWindow() -ne $window){throw 'Only the isolated Tasks window may be captured'}
        $bounds=New-Object TasksPreviewFrame+Bounds
        if([TasksPreviewFrame]::DwmGetWindowAttribute($window,9,[ref]$bounds,16) -ne 0){throw 'Tasks window bounds are unavailable'}
        $image=New-Object System.Drawing.Bitmap(($bounds.Right-$bounds.Left),($bounds.Bottom-$bounds.Top))
        $drawing=[System.Drawing.Graphics]::FromImage($image)
        try {
          $drawing.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$image.Size)
          $image.Save((Join-Path $out ($stage.name+'.png')),[System.Drawing.Imaging.ImageFormat]::Png)
        } finally {$drawing.Dispose();$image.Dispose()}
        $captured[$stage.name]=$true
        New-Item -ItemType File (Join-Path $data ($stage.name+'.ack')) | Out-Null
      }
    }
    Start-Sleep -Milliseconds 100
  }
  Copy-Item "$data\result.json" "$out\desktop-checks.json"
  if($Resume -eq 'visual') {
    Copy-Item "$data\*.png" $out
    $captured=@{}
    Get-ChildItem "$out\*.png" | ForEach-Object {$captured[$_.Name]=$true}
  }
  if(Test-Path "$data\failure.json"){Copy-Item "$data\failure.json" "$out\failure.json"}
  @{at=(Get-Date).ToUniversalTime().ToString('o');screenshots=$captured.Count;processId=$app.Id;isolated=$true;source=$Source;capture= $(if($Resume -eq 'visual'){'xaml-render'}else{'desktop-window'})} | ConvertTo-Json | Set-Content "$out\desktop.json"
} catch {
  @{ok=$false;type=$_.Exception.GetType().Name;message=$_.Exception.Message} | ConvertTo-Json | Set-Content "$out\desktop-error.json"
} finally {
  if($app){
    $app.Refresh()
    if(-not $app.HasExited -and $app.StartTime.ToUniversalTime() -eq $identity -and $app.Path -eq $exe){
      $app.CloseMainWindow() | Out-Null
      if(-not $app.WaitForExit(5000)){Stop-Process -Id $app.Id}
    }
  }
  @{at=(Get-Date).ToUniversalTime().ToString('o');ownedProcesses=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe}).Count} | ConvertTo-Json | Set-Content "$out\process-cleanup.json"
}
