param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Run, [string]$OnlyCheck='')
$ErrorActionPreference='Stop'
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-w6-projects-agents(?:-[a-z0-9]+)?$'){throw 'Use a unique W6 run name'}
if(-not [IO.Path]::GetFullPath($Source).StartsWith('C:\TD\projects-agents-source\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use an isolated source folder'}
$data="C:\TD\projects-agents-proof\$Run"
$proof=Join-Path $data 'proof'
$evidence="C:\TD\out\$Run"
if(Test-Path $data){throw 'This preview root already exists; choose a new run'}
New-Item -ItemType Directory $proof -Force | Out-Null
New-Item -ItemType Directory $evidence -Force | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ProjectAgentPreviewFrame {
  [StructLayout(LayoutKind.Sequential)] public struct Bounds { public int Left,Top,Right,Bottom; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window,int attribute,out Bounds bounds,int size);
}
'@
[ProjectAgentPreviewFrame]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
$app=$null
$phase='launch'
try {
  $env:TD_W6_ONLY_CHECK=$OnlyCheck
  $exe=Join-Path $Source 'tests\TerminalDeck.ProjectsAgents.Proof\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.ProjectsAgents.Proof.exe'
  $app=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList @('--user-data-dir',$data) -PassThru
  $identity=$app.StartTime.ToUniversalTime()
  $captured=@{}
  $until=(Get-Date).AddMinutes(3)
  while(-not (Test-Path "$proof\result.json")) {
    $app.Refresh()
    if($app.HasExited){throw 'The isolated preview exited before finishing'}
    if((Get-Date) -gt $until){throw 'The isolated preview timed out'}
    if(Test-Path "$proof\stage.json") {
      $stage=$null
      try {$stage=Get-Content "$proof\stage.json" -Raw | ConvertFrom-Json} catch {}
      if($stage -and $stage.name -match '^[0-9]{2}-[a-z-]+$' -and -not $captured.ContainsKey($stage.name)) {
        $phase='foreground'
        if($app.SessionId -eq 0 -or $app.SessionId -ne (Get-Process -Id $PID).SessionId){throw 'Preview is outside this interactive desktop'}
        $window=$app.MainWindowHandle
        [ProjectAgentPreviewFrame]::SetForegroundWindow($window) | Out-Null
        Start-Sleep -Milliseconds 350
        if([ProjectAgentPreviewFrame]::GetForegroundWindow() -ne $window){throw 'Preview is not foreground; no other window will be captured'}
        $phase='capture'
        $bounds=New-Object ProjectAgentPreviewFrame+Bounds
        if([ProjectAgentPreviewFrame]::DwmGetWindowAttribute($window,9,[ref]$bounds,16) -ne 0){throw 'Preview bounds are unavailable'}
        $image=New-Object System.Drawing.Bitmap(($bounds.Right-$bounds.Left),($bounds.Bottom-$bounds.Top))
        $drawing=[System.Drawing.Graphics]::FromImage($image)
        try {
          $drawing.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$image.Size)
          $image.Save((Join-Path $evidence ($stage.name+'.png')),[System.Drawing.Imaging.ImageFormat]::Png)
        } finally {$drawing.Dispose();$image.Dispose()}
        $captured[$stage.name]=$true
        New-Item -ItemType File (Join-Path $proof ($stage.name+'.ack')) | Out-Null
      }
    }
    Start-Sleep -Milliseconds 150
  }
  Copy-Item "$proof\result.json" "$evidence\preview-checks.json"
  if(Test-Path "$proof\failure-location.json"){Copy-Item "$proof\failure-location.json" "$evidence\failure-location.json"}
  if(Test-Path "$proof\unhandled.json"){Copy-Item "$proof\unhandled.json" "$evidence\unhandled.json"}
  if(Test-Path "$proof\frame-metrics.json"){Copy-Item "$proof\frame-metrics.json" "$evidence\frame-metrics.json"}
  if(Test-Path "$proof\initial-frame-metrics.json"){Copy-Item "$proof\initial-frame-metrics.json" "$evidence\initial-frame-metrics.json"}
  @{timestamp=(Get-Date).ToUniversalTime().ToString('o');screenshots=$captured.Count;appSession=$app.SessionId;runnerSession=(Get-Process -Id $PID).SessionId;isolated=$true} | ConvertTo-Json | Set-Content "$evidence\desktop-status.json"
} catch {
  @{ok=$false;errorType=$_.Exception.GetType().Name;code=$_.Exception.HResult.ToString('X8');phase=$phase;stage=$stage.name} | ConvertTo-Json | Set-Content "$evidence\desktop-error.json"
} finally {
  if($app){
    $app.Refresh()
    if(-not $app.HasExited -and $app.StartTime.ToUniversalTime() -eq $identity -and $app.Path -eq $exe){
      $app.CloseMainWindow() | Out-Null
      if(-not $app.WaitForExit(5000)){Stop-Process -Id $app.Id}
    }
  }
}
