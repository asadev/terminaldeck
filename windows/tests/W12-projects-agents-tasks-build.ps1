param([ValidateSet('all','tasks','projects-agents')][string]$OnlyArea='all')
# Isolated W12 checkout only; never installs or launches the attended app.
$ErrorActionPreference='Stop'
$p='C:\TD\work\w12-projects-agents-tasks'
if(!(Test-Path $p)){git clone --branch lane/win-w12-projects-agents-tasks C:/TD/td-windows.git $p;if($LASTEXITCODE){exit $LASTEXITCODE}}
if(git -C $p status --porcelain){throw 'Scratch checkout is dirty'}
git -C $p fetch origin
git -C $p checkout --detach origin/lane/win-w12-projects-agents-tasks
$lock='C:\TD\locks\build'
$deadline=(Get-Date).AddMinutes(18)
$acquired=$false
while(!$acquired){
 try{New-Item -ItemType Directory $lock -ErrorAction Stop|Out-Null;$acquired=$true}
 catch{if((Get-Date)-gt $deadline){Write-Output 'BUILD_LOCK_BUSY';exit 22};Start-Sleep -Seconds 2}
}
Write-Output 'Build lock acquired.'
try{
 (Get-Process -Id $PID).PriorityClass='BelowNormal'
 $env:MSBUILDDISABLENODEREUSE='1'
 foreach($owned in $(if($OnlyArea -eq 'tasks'){@('tests\TerminalDeck.Tasks.Proof\obj')}elseif($OnlyArea -eq 'projects-agents'){@('tests\TerminalDeck.ProjectsAgents.Proof\obj')}else{@('src\TerminalDeck.App\obj','tests\TerminalDeck.ProjectsAgents.Proof\obj','tests\TerminalDeck.Tasks.Proof\obj')})) {
  $candidate=Join-Path $p $owned
  if(Test-Path $candidate){Remove-Item $candidate -Recurse -Force}
 }
 Set-Location $p
 foreach($project in $(if($OnlyArea -eq 'tasks'){@('tests/TerminalDeck.Tasks.Proof/TerminalDeck.Tasks.Proof.csproj')}elseif($OnlyArea -eq 'projects-agents'){@('tests/TerminalDeck.ProjectsAgents.Proof/TerminalDeck.ProjectsAgents.Proof.csproj')}else{@('src/TerminalDeck.App/TerminalDeck.App.csproj','tests/TerminalDeck.ProjectsAgents.Proof/TerminalDeck.ProjectsAgents.Proof.csproj','tests/TerminalDeck.Tasks.Proof/TerminalDeck.Tasks.Proof.csproj')})) {
  $name=[IO.Path]::GetFileNameWithoutExtension($project)
  $log="C:\TD\out\w12-$name-build.log"
  dotnet build $project -c Release -p:Platform=x64 -m:1 -nr:false -p:UseSharedCompilation=false -v:quiet *> $log
  $result=$LASTEXITCODE
  Write-Output $name
  Get-Content $log -Tail 28
  if($result){exit $result}
 }
 exit 0
}finally{Remove-Item $lock}
