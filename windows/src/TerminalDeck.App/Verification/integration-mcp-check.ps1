param([ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Run='20261029T030000Z-integrated')
$ErrorActionPreference='Stop'
$runRoot=Join-Path 'C:\TD\w4-runs' $Run
$root=Join-Path $runRoot 'scratch'
$connection=Get-Content "$root\mcp\connection.json" -Raw | ConvertFrom-Json
$headers=@{Authorization='Bearer '+$connection.token}
$passed=@();$failed=@()
function Rpc($method,$params,$id){
 $body=@{jsonrpc='2.0';id=$id;method=$method;params=$params}|ConvertTo-Json -Depth 10 -Compress
 $response=Invoke-WebRequest -UseBasicParsing -Uri $connection.url -Method Post -Headers $headers -ContentType application/json -Body $body
 return $response.Content|ConvertFrom-Json
}
try {
 $hello=Rpc initialize @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='w4-check';version='1'}} 1
 if($hello.result.serverInfo.name -eq 'deck-control'){$passed+='Authenticated MCP initialization'}else{$failed+='MCP initialization'}
 $list=Rpc tools/list @{} 2
 $names=@($list.result.tools.name)
 if($names.Count -ge 20){$passed+='Live integrated tools catalogue'}else{$failed+='Tools catalogue'}
 $sessions=Rpc tools/call @{name='sessions_list';arguments=@{}} 3
 if($sessions.result.isError -eq $false -and $sessions.result.content[0].text -match 'W4 PowerShell'){$passed+='MCP lists the live PowerShell session'}else{$failed+='MCP sessions list'}
 $browser=Rpc tools/call @{name='browser_windows';arguments=@{action='list'}} 4
 if($browser.result.isError -eq $false -and $browser.result.content[0].text -match 'example.com'){$passed+='MCP sees Core browser metadata'}else{$failed+='MCP browser list'}
 try {Invoke-WebRequest -UseBasicParsing -Uri $connection.url -Method Post -Headers @{Authorization='Bearer invalid-token'} -ContentType application/json -Body '{}' | Out-Null; $failed+='Invalid MCP token accepted'} catch {if([int]$_.Exception.Response.StatusCode -eq 401){$passed+='Unauthenticated requests refused'}else{$failed+='Unexpected auth response'}}
 @{passed=$passed;failed=$failed;passCount=$passed.Count;failCount=$failed.Count;toolCount=$names.Count;timestamp=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $runRoot 'mcp-result.json')
} catch { @{passed=$passed;failed=@('MCP check stopped');passCount=$passed.Count;failCount=1}|ConvertTo-Json|Set-Content (Join-Path $runRoot 'mcp-result.json');exit 1 }
