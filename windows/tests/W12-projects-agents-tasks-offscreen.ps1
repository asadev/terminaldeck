param([Parameter(Mandatory=$true)][string]$Run, [ValidateSet('all','projects-agents','tasks')][string]$OnlyArea='all')
$ErrorActionPreference='Stop'
if($Run -notmatch '^[0-9]{8}T[0-9]{6}Z-w12-pat$'){throw 'Use a unique W12 run name'}
$source='C:\TD\work\w12-projects-agents-tasks'
$out="C:\TD\out\$Run"
if(Test-Path $out){throw 'Evidence already exists'}
New-Item -ItemType Directory $out|Out-Null
(Get-Process -Id $PID).PriorityClass='BelowNormal'
$env:TD_W12_OFFSCREEN='1'
$results=@()
$selectedAreas=if($OnlyArea -eq 'tasks'){@('Tasks')}elseif($OnlyArea -eq 'projects-agents'){@('ProjectsAgents')}else{@('ProjectsAgents','Tasks')}
foreach($area in $selectedAreas) {
 $lower=if($area -eq 'ProjectsAgents'){'projects-agents'}else{'tasks'}
 $data="C:\TD\$lower-proof\$Run"
 if(Test-Path $data){throw 'Scratch root already exists'}
 New-Item -ItemType Directory "$data\temp"|Out-Null
 $env:TEMP="$data\temp";$env:TMP="$data\temp"
 $exe="$source\tests\TerminalDeck.$area.Proof\bin\x64\Release\net10.0-windows10.0.19041.0\TerminalDeck.$area.Proof.exe"
 $result=if($area -eq 'ProjectsAgents'){"$data\proof\result.json"}else{"$data\result.json"}
 $app=$null
 try {
  $app=Start-Process $exe -WorkingDirectory (Split-Path $exe) -ArgumentList @('--user-data-dir',$data) -PassThru
  $identity=$app.StartTime.ToUniversalTime()
  $deadline=(Get-Date).AddMinutes(2)
  while(!(Test-Path $result)) {
   if($app.HasExited){throw "$area fixture exited before writing its result"}
   if((Get-Date)-gt $deadline){throw "$area fixture timed out"}
   Start-Sleep -Milliseconds 200;$app.Refresh()
  }
  $dest=Join-Path $out $lower;New-Item -ItemType Directory $dest|Out-Null
  $evidence=Split-Path $result
  Get-ChildItem $evidence -File|Where-Object {$_.Extension -in @('.png','.json')}|Copy-Item -Destination $dest
  $resultData=Get-Content $result -Raw|ConvertFrom-Json
  $results+=@{area=$area;passed=$resultData.passed;failed=$resultData.failed}
 } finally {
  if($app){
   $app.Refresh()
   if(!$app.HasExited -and $app.StartTime.ToUniversalTime() -eq $identity -and $app.Path -eq $exe){
    $app.CloseMainWindow()|Out-Null
    if(!$app.WaitForExit(5000)){Stop-Process -Id $app.Id}
   }
  }
 }
}
@{at=(Get-Date).ToUniversalTime().ToString('o');capture='offscreen XAML RenderTargetBitmap';source=$source;results=$results}|ConvertTo-Json -Depth 8|Set-Content "$out\summary.json"
