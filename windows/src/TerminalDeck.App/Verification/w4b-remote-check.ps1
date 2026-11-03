param([ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Run)
$ErrorActionPreference='Stop'
$runRoot=Join-Path 'C:\TD\w4-runs' $Run
$proof=Join-Path $runRoot 'scratch\w4b'
$deadline=(Get-Date).AddMinutes(4)
while(!(Test-Path "$proof\remote-ready")) { if((Get-Date) -gt $deadline){throw 'The main app did not reach its remote proof.'};Start-Sleep -Milliseconds 200 }
$passed=@();$failed=@()
try {
 $connection=Get-Content "$runRoot\scratch\mcp\remote-connection.json" -Raw | ConvertFrom-Json
 $headers=@{Authorization='Bearer '+$connection.token}
 function Rpc($method,$params,$id){
  $body=@{jsonrpc='2.0';id=$id;method=$method;params=$params}|ConvertTo-Json -Depth 10 -Compress
  $response=Invoke-WebRequest -UseBasicParsing -Uri $connection.url -Method Post -Headers $headers -ContentType application/json -Body $body -TimeoutSec 20
  return $response.Content|ConvertFrom-Json
 }
 $hello=Rpc initialize @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='w4b-relay-proof';version='1'}} 1
 if($hello.result.serverInfo.name -eq 'deck-control'){$passed+='Real relay authenticated initialization'}else{$failed+='Relay initialization'}
 $list=Rpc tools/list @{} 2
 if(@($list.result.tools.name).Contains('sessions_account') -and @($list.result.tools.name).Contains('browser_read')){$passed+='Real relay exposes integrated account and browser tools'}else{$failed+='Relay tool catalogue'}
 $read=Rpc tools/call @{name='sessions_list';arguments=@{}} 3
 if($read.result.isError -eq $false -and $read.result.content[0].text -match 'W4 PowerShell'){$passed+='Real relay reads the main PC session'}else{$failed+='Relay session read'}
 $local=Get-Content "$runRoot\scratch\mcp\connection.json" -Raw | ConvertFrom-Json
 try {Invoke-WebRequest -UseBasicParsing -Uri $connection.url -Method Post -Headers @{Authorization='Bearer '+$local.token} -ContentType application/json -Body '{"jsonrpc":"2.0","id":4,"method":"ping"}' -TimeoutSec 20|Out-Null;$failed+='Local-only token accepted by relay'} catch {if([int]$_.Exception.Response.StatusCode -eq 401){$passed+='Real relay rejects a local-only token'}else{$failed+='Unexpected local-only token response'}}
} catch { $failed+='Real relay proof could not complete' }
finally {
 @{passed=$passed;failed=$failed;passCount=$passed.Count;failCount=$failed.Count;timestamp=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json -Depth 6|Set-Content "$runRoot\remote-result.json"
 New-Item -ItemType File "$proof\remote-finish" -Force | Out-Null
}
