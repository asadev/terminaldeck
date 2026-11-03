param([Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$proof=Join-Path $PSScriptRoot 'bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.AdapterProof.exe'
$keeper=Join-Path $root 'TerminalDeck.Keeper\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.Keeper.exe'
if (!(Test-Path $proof) -or !(Test-Path $keeper)) { throw 'Build the proof window and keeper in Release x64 first' }
$Evidence=[IO.Path]::GetFullPath($Evidence)
if (!$Evidence.StartsWith('C:\TD\out\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Use an evidence folder under C:\TD\out' }
New-Item -ItemType Directory -Force $Evidence | Out-Null
$data='C:\TD\out\w3-proof-data\'+[Guid]::NewGuid().ToString('N')
$own=$null
function Start-Proof([string]$phase) {
  $arguments='"'+$data+'" "'+$Evidence+'" "'+$keeper+'" '+$phase
  Start-Process -FilePath $proof -ArgumentList $arguments -PassThru
}
function Wait-Proof([string]$name) {
  for ($i=0;$i -lt 900;$i++) {
    if (Test-Path (Join-Path $Evidence $name)) { return Get-Content (Join-Path $Evidence $name) -Raw | ConvertFrom-Json }
    $failed=Get-ChildItem $Evidence -Filter '*-failed.json' | Select-Object -First 1
    if ($failed) { throw (Get-Content $failed.FullName -Raw) }
    Start-Sleep -Milliseconds 100
  }
  throw "Proof did not write $name"
}
function Stop-OwnedKeeper {
  $path=Join-Path $data 'keeper\supervisor.identity.json'
  if (Test-Path $path) {
    $identity=Get-Content $path -Raw | ConvertFrom-Json
    $process=Get-Process -Id $identity.Pid -ErrorAction SilentlyContinue
    if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $identity.StartedUtcTicks) { Stop-Process -Id $process.Id -Force }
  }
}
try {
  $own=Start-Proof 'first'
  $first=Wait-Proof 'first-ready.json'
  $workerPath=Join-Path $data "keeper\workers\$($first.lease).identity.json"
  $workerBefore=Get-Content $workerPath -Raw
  Stop-Process -Id $own.Id -Force; $own.WaitForExit(); $own=$null
  $own=Start-Proof 'second'
  $second=Wait-Proof 'second-ready.json'
  if (!$second.markerSeen -or $second.lease -ne $first.lease) { throw 'App restart lost the original terminal' }
  Stop-Process -Id $own.Id -Force; $own.WaitForExit(); $own=$null
  Stop-OwnedKeeper
  $own=Start-Proof 'third'
  $third=Wait-Proof 'third-ready.json'
  $browser=Wait-Proof 'browser-proof.json'
  $sameWorker=$workerBefore -eq (Get-Content $workerPath -Raw)
  if (!$third.markerSeen -or $third.lease -ne $first.lease -or !$sameWorker) { throw 'Keeper restart replaced or lost the original worker' }
  @{ appCrashSurvived=$true; keeperCrashSurvived=$true; sameLease=$true; sameWorker=$sameWorker; markerSeen=$true; browser=$browser; dataRoot=$data; app='TerminalDeck.AdapterProof.exe (isolated proof window)' } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence 'survival-proof.json')
} finally {
  if ($own -and !$own.HasExited) { Stop-Process -Id $own.Id -Force; $own.WaitForExit() }
  if (Test-Path (Join-Path $data 'state\sessions.json')) {
    $cleanup=Start-Proof 'cleanup'
    if (!$cleanup.WaitForExit(20000)) { Stop-Process -Id $cleanup.Id -Force }
  }
  Stop-OwnedKeeper
}
