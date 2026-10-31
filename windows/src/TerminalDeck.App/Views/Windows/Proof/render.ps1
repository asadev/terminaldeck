param([string]$Checkout='C:\TD\work\92c47c15948720acca8af53dbc2478442139e2b50b1d50d2fa72b6790e5d66cd', [string]$Run='p-shell-proof')
$ErrorActionPreference='Stop'
if ($Run -notmatch '^p-shell-[a-zA-Z0-9-]+$') { throw 'Use a shell-specific run name.' }
# C:\TD previews share a per-user Windows share-target pointer. A root outside
# that tree keeps this test from changing the pointer used by the review app.
$root="C:\TD-ShellProof\$Run"
if (Test-Path $root) { throw 'Use a fresh proof root.' }
$proof=Join-Path $root 'proof'
New-Item -ItemType Directory -Force $proof | Out-Null
$env:TD_SHELL_PROOF=$proof
$exe=Join-Path $Checkout 'src\TerminalDeck.App\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.App.exe'
$app=Start-Process $exe -ArgumentList "--user-data-dir $root" -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized -PassThru
@{pid=$app.Id;root=$root;checkout=$Checkout;started=$app.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content "$root\owned-app.json"
$deadline=(Get-Date).AddMinutes(4)
while (!(Test-Path "$proof\result.json")) {
  if ((Get-Date) -gt $deadline) { throw 'Shell proof timed out; inspect the owned process before cleanup.' }
  $app.Refresh()
  if ($app.HasExited) { throw 'Shell proof exited before writing a result.' }
  Start-Sleep -Milliseconds 300
}
Get-Content "$proof\result.json"
# Do not terminate by process name. The app closes itself after the fixture.
# The keeper intentionally survives normal app exits: clean up only the owned
# namespace with the identity/readback procedure in README.md.
