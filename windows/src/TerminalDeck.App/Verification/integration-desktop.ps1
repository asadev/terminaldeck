param([ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Run,[ValidateSet('create','restart','recovery','settings','delta','cleanup','inspect','w4b','browser-read','account-add')][string]$Phase,[ValidatePattern('^C:\\TD\\work\\[A-Za-z0-9._-]+$')][string]$Checkout='C:\TD\work\win-integrate')
$ErrorActionPreference='Stop'
. C:\TD\setup\env.ps1
$runRoot=Join-Path 'C:\TD\w4-runs' $Run
$root=Join-Path $runRoot 'scratch'
New-Item -ItemType Directory -Force (Join-Path $runRoot 'temp') | Out-Null
$env:TEMP=Join-Path $runRoot 'temp'; $env:TMP=$env:TEMP
$proof=Join-Path $root $Phase
New-Item -ItemType Directory -Force $proof | Out-Null
$env:TD_INTEGRATION_PROOF=$proof
$env:TD_INTEGRATION_PHASE=$Phase
$app=$null
try {
 $exe=Join-Path $Checkout 'src\TerminalDeck.App\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.App.exe'
 $app=Start-Process $exe -ArgumentList "--user-data-dir $root" -WorkingDirectory (Split-Path $exe) -PassThru
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class W4Window {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 public delegate bool EnumWindowCallback(IntPtr hwnd, IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder title, int length);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd,int attribute,out RECT rect,int size);
}
'@
 [W4Window]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
 Add-Type -AssemblyName System.Drawing
 $deadline=(Get-Date).AddMinutes(40)
 $captured=@{}
 while(-not (Test-Path "$proof\result.json")) {
  if((Get-Date) -gt $deadline){throw 'Proof timed out.'}
  $app.Refresh()
  if($app.HasExited){throw 'App exited before proof finished.'}
  if((Test-Path "$proof\kill-keeper.request") -and -not (Test-Path "$proof\kill-keeper.ack")) {
   $identity=Get-Content "$root\keeper\supervisor.identity.json" -Raw | ConvertFrom-Json
   $keeper=Get-Process -Id $identity.Pid
   if($keeper.ProcessName -ne 'TerminalDeck.Keeper' -or $keeper.StartTime.ToUniversalTime().Ticks -ne $identity.StartedUtcTicks){throw 'Keeper identity changed; refusing to kill it.'}
   Stop-Process -Id $keeper.Id
   New-Item -ItemType File "$proof\kill-keeper.ack" | Out-Null
  }
  if(Test-Path "$proof\stage.json") {
   try { $stage=Get-Content "$proof\stage.json" -Raw | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 100; continue }
   $name=$stage.name
   if($name -and -not $captured.ContainsKey($name)) {
    $hwnd=$app.MainWindowHandle
    if($name -eq '13-inspector-window') {
     $owned=@{}; $owned[$app.Id]=$true
     $processes=Get-CimInstance Win32_Process
     for($depth=0;$depth -lt 8;$depth++){foreach($child in $processes){if($owned.ContainsKey([int]$child.ParentProcessId)){$owned[[int]$child.ProcessId]=$true}}}
     $script:inspector=[IntPtr]::Zero
     [W4Window]::EnumWindows({param($candidate,$data)
       $ownerId=[uint32]0;[W4Window]::GetWindowThreadProcessId($candidate,[ref]$ownerId)|Out-Null
       if($owned.ContainsKey([int]$ownerId) -and [W4Window]::IsWindowVisible($candidate)){
        $title=New-Object System.Text.StringBuilder 1024;[W4Window]::GetWindowText($candidate,$title,1024)|Out-Null
        if($title.ToString() -match 'DevTools|Developer Tools'){$script:inspector=$candidate}
       }
       return $true
     },[IntPtr]::Zero)|Out-Null
     if($script:inspector -eq [IntPtr]::Zero){throw 'No visible inspector belonging to this app was found.'}
     $hwnd=$script:inspector
    }
    for($focusAttempt=0;$focusAttempt -lt 4;$focusAttempt++) {
     $app.Refresh(); if($name -ne "13-inspector-window"){$hwnd=$app.MainWindowHandle}
     [W4Window]::SetForegroundWindow($hwnd) | Out-Null
     Start-Sleep -Milliseconds 400
     if([W4Window]::GetForegroundWindow() -eq $hwnd){break}
    }
    if([W4Window]::GetForegroundWindow() -ne $hwnd){throw 'App is not in front; refusing to capture another application.'}
    $rect=New-Object W4Window+RECT
    if([W4Window]::DwmGetWindowAttribute($hwnd,9,[ref]$rect,16) -ne 0){throw 'Could not get the app frame.'}
    $bitmap=New-Object System.Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
    $bitmap.Save("$runRoot\$name.png",[System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose(); $captured[$name]=$true
    New-Item -ItemType File "$proof\$name.ack" | Out-Null
   }
  }
  Start-Sleep -Milliseconds 100
 }
 Copy-Item "$proof\result.json" "$runRoot\$Phase-result.json"
 @{Timestamp=(Get-Date).ToString('o');TaskSession=(Get-Process -Id $PID).SessionId;AppSession=$app.SessionId;ProcessId=$app.Id;Captures=$captured.Count;Phase=$Phase} | ConvertTo-Json | Set-Content "$runRoot\$Phase-desktop.json"
} catch { $_ | Out-String | Set-Content "$runRoot\$Phase-failure.txt"; exit 1 }
finally {
 if($app -and -not $app.HasExited){$app.CloseMainWindow() | Out-Null; if(-not $app.WaitForExit(5000)){Stop-Process -Id $app.Id}}
}
