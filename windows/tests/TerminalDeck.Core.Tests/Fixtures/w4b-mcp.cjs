const readline = require('node:readline');
const http = require('node:http');
const mode = process.argv[2];
function reply(message) {
  if (message.id === undefined) return null;
  let result = {};
  if (message.method === 'initialize') result = {protocolVersion:'2025-06-18',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}};
  if (message.method === 'tools/list') result = message.params.cursor ? {tools:[{name:'second',inputSchema:{type:'object'}}]} : {tools:[{name:'echo',title:'Echo text',description:'Echo the supplied text',inputSchema:{type:'object'}}],nextCursor:'next'};
  if (message.method === 'tools/call') result = {content:[{type:'text',text:message.params.arguments.text}]};
  return {jsonrpc:'2.0',id:message.id,result};
}
if (mode === 'stdio') {
  readline.createInterface({input:process.stdin}).on('line',line=>{const r=reply(JSON.parse(line));if(r){process.stdout.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/message',params:{}})+'\n');process.stdout.write(JSON.stringify(r)+'\n');}});
} else {
  let events;
  const server=http.createServer((req,res)=>{
    if (mode==='redirect') {res.writeHead(302,{Location:'http://127.0.0.1:1/elsewhere'});res.end();return;}
    if (req.method==='GET') {
      res.writeHead(200,{'Content-Type':'text/event-stream'});res.write(':heartbeat\n\nevent: endpoint\ndata: '+(mode==='unsafe'?'http://example.invalid/post':'/post?session=fixture')+'\n\n');events=res;return;
    }
    let body='';req.on('data',chunk=>body+=chunk);req.on('end',()=>{
      const message=JSON.parse(body);const r=reply(message);
      if (!r) {res.writeHead(202);res.end();return;}
      if(mode==='sse'){res.writeHead(202);res.end();events.write('event: message\ndata: '+JSON.stringify(r)+'\n\n');return;}
      res.writeHead(200,{'Content-Type':'text/event-stream','Mcp-Session-Id':'fixture-session'});
      res.end(':heartbeat\n\nevent: message\ndata: '+JSON.stringify({jsonrpc:'2.0',method:'notifications/message',params:{}})+'\n\nevent: message\ndata: '+JSON.stringify(r)+'\n\n');
    });
  });server.listen(0,'127.0.0.1',()=>process.stdout.write(JSON.stringify({port:server.address().port})+'\n'));
}
