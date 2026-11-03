param([ValidateSet('screens','checks')][string]$Mode='screens', [string]$Run='visual-v1')
$ErrorActionPreference='Stop'
. C:\TD\setup\env.ps1
$project='C:\TD\td-windows-ui\src\TerminalDeck.App'
$runRoot=Join-Path 'C:\TD\ui-proof' $Run
if(Test-Path $runRoot){throw 'Choose a fresh run folder; old proof is never overwritten.'}
$proof=Join-Path $runRoot 'scratch\proof'
New-Item -ItemType Directory -Force $proof | Out-Null
$env:TD_UI_PROOF_DIR=$proof
$env:TD_UI_PROOF_MODE=$Mode
$env:TD_UI_FIXTURE='http://127.0.0.1:18765/'
$fixture=$null
$app=$null
try {
  $fixture=Start-Process 'C:\Program Files\nodejs\node.exe' -ArgumentList "$project\Verification\fixture.cjs" -RedirectStandardOutput "$runRoot\fixture.log" -RedirectStandardError "$runRoot\fixture-error.log" -PassThru
  Start-Sleep -Seconds 1
  $fixture.Refresh()
  if($fixture.HasExited){throw 'The local fixture could not start; no existing process was touched.'}
  $exe="$project\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.App.exe"
  $app=Start-Process $exe -ArgumentList "--user-data-dir $runRoot\scratch" -WorkingDirectory (Split-Path $exe) -PassThru
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TDUIWindow {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
}
'@
  [TDUIWindow]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
  Add-Type -AssemblyName System.Drawing
  $deadline=(Get-Date).AddMinutes(3)
  $captured=@{}
  while(-not (Test-Path "$proof\result.json")) {
    if((Get-Date) -gt $deadline){throw 'The preview proof timed out.'}
    $app.Refresh()
    if($app.HasExited){throw 'The preview exited before proof finished.'}
    if(Test-Path "$proof\stage.json") {
      try { $stage=Get-Content "$proof\stage.json" -Raw | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 100; continue }
      $name=$stage.name
      if($name -and -not $captured.ContainsKey($name)) {
        $hwnd=$app.MainWindowHandle
        [TDUIWindow]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 300
        if([TDUIWindow]::GetForegroundWindow() -ne $hwnd){throw 'Preview is not in front; refusing to capture another application.'}
        $rect=New-Object TDUIWindow+RECT
        if([TDUIWindow]::DwmGetWindowAttribute($hwnd,9,[ref]$rect,16) -ne 0){throw 'Could not get the visible preview frame.'}
        $bitmap=New-Object System.Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
        $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
        $bitmap.Save("$runRoot\$name.png",[System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        $captured[$name]=$true
        New-Item -ItemType File "$proof\$name.ack" | Out-Null
      }
    }
    Start-Sleep -Milliseconds 100
  }
  Copy-Item "$proof\result.json" "$runRoot\result.json"
  @{Timestamp=(Get-Date).ToString('o');TaskSession=(Get-Process -Id $PID).SessionId;AppSession=$app.SessionId;ProcessId=$app.Id;Captures=$captured.Count;Mode=$Mode} | ConvertTo-Json | Set-Content "$runRoot\desktop.json"
} catch {
  $_ | Out-String | Set-Content "$runRoot\failure.txt"
  exit 1
} finally {
  if($app -and -not $app.HasExited){$app.CloseMainWindow() | Out-Null}
  if($fixture -and -not $fixture.HasExited){Stop-Process -Id $fixture.Id}
}
