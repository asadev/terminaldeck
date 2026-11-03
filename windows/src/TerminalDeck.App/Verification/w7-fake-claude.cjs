// Synthetic stream-json CLI: no account files, network or models.
const readline = require('node:readline');
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
let active, pending;
const complete = () => emit({type:'result',subtype:'success',is_error:false,session_id:'w7-fake-conversation'});
emit({type:'system',subtype:'init',session_id:'w7-fake-conversation'});
readline.createInterface({input:process.stdin}).on('line', line => {
  const row = JSON.parse(line);
  if (row.type === 'user') {
    active = row.uuid;
    emit({type:'user',uuid:active,message:row.message});
    const text = row.message.content.find(c=>c.type==='text')?.text || '';
    if (text.includes('queued follow-up')) { emit({type:'assistant',message:{id:'follow-up',content:[{type:'text',text:'Fake CLI received the queued follow-up.'}]}}); complete(); return; }
    const w8 = text.includes('W8 layout fixture');
    const detail = w8 ? 'A long synthetic tool result wraps across the available width. '.repeat(18) : 'Synthetic project overview read.';
    emit({type:'stream_event',event:{type:'message_start',message:{id:'demo-answer'}}});
    emit({type:'stream_event',event:{type:'content_block_delta',index:0,delta:{type:'text_delta',text:w8 ? 'A long assistant response stays inside its content-sized card. '.repeat(12) : 'This is a fake CLI demonstration. I can read the project and ask before changing a file.'}}});
    emit({type:'assistant',message:{id:'demo-tool',content:[{type:'tool_use',id:'read-step',name:'Read',input:{file_path:'README.md'}}]}});
    emit({type:'user',message:{content:[{type:'tool_result',tool_use_id:'read-step',content:detail}]}});
    pending='write-demo';
    emit({type:'control_request',request_id:pending,request:{subtype:'can_use_tool',tool_name:'Write',input:{file_path:'demo.txt',content:w8 ? 'Synthetic approval details that must remain reachable. '.repeat(16) : 'Synthetic demonstration only.'}}});
  } else if (row.type==='control_response') {
    emit({type:'assistant',message:{id:'approval-answer',content:[{type:'text',text:'The fake approval reply arrived.'}]}}); complete();
  } else if (row.type==='control_request' && row.request?.subtype==='interrupt') complete();
});
