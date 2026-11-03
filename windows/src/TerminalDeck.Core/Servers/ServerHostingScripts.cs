using System.Text.Json;
namespace TerminalDeck.Core.Servers;

public static class ServerHostingScripts
{
  public const string Version = "1";
  public static ServerCommand Command(string action, object? settings)
  {
    if (action is not ("read" or "setup" or "remove" or "save-alerts" or "test-alerts")) throw new ServerRefusal("Choose a supported hosting action.");
    var input = JsonSerializer.Serialize(new { action, settings, watcher = Monitor, manager = Manage }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
    var program = "__DECK_MANAGE_SOURCE__=" + JsonSerializer.Serialize(Manage) + "\nexec(__DECK_MANAGE_SOURCE__)";
    return new("python3 -c " + ServerValidation.Quote(program), input, 262144);
  }
  private const string Manage = """
import os,sys,json,subprocess,pathlib,tempfile,datetime,copy,shutil,platform,pwd
p=json.load(sys.stdin); action=p['action']; base=pathlib.Path('/etc/terminaldeck-windows'); version='1'
def cmd(args):
 r=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=10); return r.returncode,r.stdout.strip()
def safe():
 for f in (pathlib.Path('/etc'),base):
  if f.is_symlink(): raise RuntimeError('The helper folder must not be a symlink')
def write(path,text,mode=0o600):
 if path.is_symlink(): raise RuntimeError('A helper file must not be a symlink')
 fd,tmp=tempfile.mkstemp(prefix='.deck-',dir=path.parent)
 try:
  os.fchmod(fd,mode)
  with os.fdopen(fd,'w') as f: f.write(text); f.flush(); os.fsync(f.fileno())
  os.replace(tmp,path)
 finally:
  if os.path.exists(tmp): os.unlink(tmp)
def read(name,default):
 f=base/name
 if f.is_symlink(): raise RuntimeError('A helper file must not be a symlink')
 try:
  if f.stat().st_size>262144: raise RuntimeError('Helper settings are too large')
  return json.loads(f.read_text())
 except (FileNotFoundError,PermissionError): return default
safe(); admin=os.geteuid()==0
if not admin:
 code=cmd(['sudo','-n','true'])[0] if shutil.which('sudo') else 1
 if code and action!='read': raise RuntimeError('This action needs root or passwordless sudo')
 # Re-execute the fixed source with the same request. No request field is code.
 if not code:
  r=subprocess.run(['sudo','-n','python3','-c',__DECK_MANAGE_SOURCE__],input=json.dumps(p),text=True); sys.exit(r.returncode)
if action=='setup' and not shutil.which('docker'):
 if not shutil.which('systemd-run') or not pathlib.Path('/run/systemd/system').exists(): raise RuntimeError('Setup needs a Linux server running systemd')
 base.mkdir(mode=0o755,exist_ok=True); os.chmod(base,0o755)
 pending=read('setup-state.json',{})
 if pending.get('state')!='running':
  payload=json.dumps(p)
  worker='import os,json,pathlib,urllib.request,subprocess,tempfile,datetime\n'+'p=json.loads('+repr(payload)+')\n'+'''base=pathlib.Path('/etc/terminaldeck-windows')
def status(state,problem=None):
 path=base/'setup-state.json'; temp=base/'setup-state.new'
 fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as f: json.dump(dict(state=state,problem=problem),f)
 os.replace(temp,path)
try:
 with urllib.request.urlopen('https://get.docker.com',timeout=30) as response:
  if response.geturl()!='https://get.docker.com': raise RuntimeError('Installer location changed')
  script=response.read(2097153)
  if not script or len(script)>2097152: raise RuntimeError('Installer size refused')
 fd,path=tempfile.mkstemp(prefix='docker-',dir=base)
 try:
  os.fchmod(fd,0o700)
  with os.fdopen(fd,'wb') as f: f.write(script)
  result=subprocess.run(['sh',path],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=900)
  if result.returncode: raise RuntimeError('Docker installer did not finish')
 finally: os.unlink(path)
 result=subprocess.run(['python3','-c',p['manager']],input=json.dumps(p),text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=120)
 if result.returncode: raise RuntimeError('Helper setup did not finish')
 status('finished')
except Exception: status('failed','Server setup did not finish. Review Docker/systemd access and try again; existing apps were kept.')
'''
  write(base/'setup.py',worker,0o700); write(base/'setup-state.json',json.dumps(dict(state='running')))
  if cmd(['systemd-run','--unit=terminaldeck-setup','--collect','/usr/bin/python3',str(base/'setup.py')])[0]:
   write(base/'setup-state.json',json.dumps(dict(state='failed',problem='The server could not start its setup job.')))
 action='read'
if action=='setup':
 if not shutil.which('systemctl') or not pathlib.Path('/run/systemd/system').exists(): raise RuntimeError('Setup needs a Linux server running systemd')
 if not shutil.which('docker'): raise RuntimeError('Install Docker on this server before setting up Apps helpers')
 base.mkdir(mode=0o755,exist_ok=True); os.chmod(base,0o755)
 write(base/'watch.py',p['watcher'],0o700); write(base/'version.json',json.dumps(version),0o644)
 unit=pathlib.Path('/etc/systemd/system')
 write(unit/'terminaldeck-watch.service','[Unit]\nDescription=Terminal Deck app and resource alerts\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /etc/terminaldeck-windows/watch.py\nNoNewPrivileges=true\nPrivateTmp=true\nProtectHome=true\n')
 write(unit/'terminaldeck-watch.timer','[Unit]\nDescription=Terminal Deck server observations\n[Timer]\nOnBootSec=60\nOnUnitActiveSec=60\nPersistent=true\n[Install]\nWantedBy=timers.target\n')
 for args in (['systemctl','daemon-reload'],['systemctl','enable','--now','terminaldeck-watch.timer']):
  if cmd(args)[0]: raise RuntimeError('The server could not enable its alert timer')
if action=='remove':
 if shutil.which('systemctl'):
  cmd(['systemctl','stop','terminaldeck-setup.service']); cmd(['systemctl','disable','--now','terminaldeck-watch.timer'])
 for name in ('terminaldeck-watch.timer','terminaldeck-watch.service'):
  f=pathlib.Path('/etc/systemd/system')/name
  if f.is_symlink(): raise RuntimeError('A helper unit must not be a symlink')
  if f.exists(): f.unlink()
 if shutil.which('systemctl'): cmd(['systemctl','daemon-reload'])
 if base.exists():
  if any(f.is_symlink() for f in base.iterdir()): raise RuntimeError('The helper folder contains a symlink')
  # Only this helper's files are removed. Application data/volumes are elsewhere.
  for name in ('watch.py','version.json','alerts.json','history.json','state.json','.watch-lock','setup.py','setup-state.json'):
   f=base/name
   if f.exists(): f.unlink()
  try: base.rmdir()
  except OSError: pass
if action in ('save-alerts','test-alerts') and not (base/'version.json').exists(): raise RuntimeError('Set up this server first')
if action=='save-alerts':
 value=p['settings']; old=read('alerts.json',{}); previous={c['id']:c for c in old.get('channels',[])}
 for channel in value.get('channels') or []:
  saved=previous.get(channel['id'],{})
  for key in ('botToken','password','secret','token'):
   if channel.get(key) in (None,'','••••••••'):
    if saved.get('kind')==channel['kind'] and saved.get(key): channel[key]=saved[key]
    else: channel.pop(key,None)
  if channel.get('enabled',True) and channel['kind']=='telegram' and not channel.get('botToken'): raise RuntimeError('Enter the Telegram bot token')
  if channel.get('enabled',True) and channel['kind']=='receiver' and not channel.get('token'): raise RuntimeError('Enter the Receiver secret')
 write(base/'alerts.json',json.dumps(value))
deliveries=[]
if action=='test-alerts':
 r=subprocess.run(['python3',str(base/'watch.py'),'--test'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=90)
 if r.returncode: raise RuntimeError('The server could not send the test alert')
 deliveries=json.loads(r.stdout)
alerts=read('alerts.json',{'enabled':False,'channels':[]}); public=copy.deepcopy(alerts)
for channel in public.get('channels') or []:
 for key in ('botToken','password','secret','token'):
  if key in channel: channel[key]='••••••••' if channel[key] else None
installed=read('version.json',None)
docker=cmd(['docker','--version'])[1] if shutil.which('docker') else None
status=dict(installed=bool(installed),administrator=admin or bool(shutil.which('sudo') and cmd(['sudo','-n','true'])[0]==0),supported=sys.platform.startswith('linux') and bool(shutil.which('systemctl')),docker=docker,hostname=os.uname().nodename,installedVersion=installed,helperVersion=version,routerSummary='Existing Docker published ports; no reverse proxy was changed.',duties=['App and resource observations every minute','Alert delivery from this server'] if installed else [],problem=None if admin else 'Administrator access is required to read or change saved alert destinations.')
listeners=cmd(['ss','-H','-ltn'])[1].splitlines()[:20] if shutil.which('ss') else []
package=next((name for name in ('apt-get','dnf','yum','apk','zypper','pacman') if shutil.which(name)),None)
setup=read('setup-state.json',{}); status['setupState']=setup.get('state'); status['setupProblem']=setup.get('problem')
status['facts']=dict(system=platform.platform(),hostname=os.uname().nodename,user=pwd.getpwuid(os.getuid()).pw_name,listeners=listeners,packageManager=package)
print(json.dumps(dict(hosting=status,alerts=public,history=read('history.json',[]) if admin else [],deliveries=deliveries)))
""";
  // Returned to the same server as literal data at setup time. It never runs on
  // this PC and never reads another app's configuration or credential store.
  public const string Monitor = """
import os,sys,json,pathlib,subprocess,datetime,time,shutil,urllib.request,smtplib,email.message,ssl,hmac,hashlib,fcntl,socket,re
base=pathlib.Path('/etc/terminaldeck-windows')
if base.is_symlink() or any((base/n).is_symlink() for n in ('alerts.json','history.json','state.json','.watch-lock')): raise RuntimeError('Linked helper state is refused')
lockfd=os.open(base/'.watch-lock',os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW,0o600); lock=os.fdopen(lockfd,'a'); fcntl.flock(lock,fcntl.LOCK_EX)
def load(name,default):
 try: return json.loads((base/name).read_text())
 except FileNotFoundError: return default
def save(name,value):
 target=base/name; temp=base/(name+'.new'); fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as f: json.dump(value,f); f.flush(); os.fsync(f.fileno())
 os.replace(temp,target)
settings=load('alerts.json',{}); history=load('history.json',[]); state=load('state.json',{}); testing='--test' in sys.argv
channels=[c for c in settings.get('channels') or [] if c.get('enabled',True)]
def deliver(message):
 result=[]
 for c in channels:
  ok=False
  try:
   kind=c['kind']; data=json.dumps({'title':'Terminal Deck server alert','text':message}).encode(); headers={'Content-Type':'application/json'}
   if kind=='telegram':
    url='https://api.telegram.org/bot'+c['botToken']+'/sendMessage'; data=json.dumps({'chat_id':c['chatId'],'text':message}).encode()
   elif kind=='email':
    from urllib.parse import urlparse
    address=urlparse(c['smtpUrl']); client=(smtplib.SMTP_SSL if address.scheme=='smtps' else smtplib.SMTP)(address.hostname,address.port or (465 if address.scheme=='smtps' else 587),timeout=2)
    with client:
     if address.scheme!='smtps': client.starttls(context=ssl.create_default_context())
     if c.get('username'): client.login(c['username'],c.get('password',''))
     mail=email.message.EmailMessage(); mail['Subject']='Terminal Deck server alert'; mail['From']=c['from']; mail['To']=', '.join(c['to']); mail.set_content(message); client.send_message(mail)
    ok=True; url=None
   else:
    url=c['url']
    if kind=='receiver': headers['Authorization']='Bearer '+c['token']
    elif c.get('secret'): headers['X-Deck-Signature']='sha256='+hmac.new(c['secret'].encode(),data,hashlib.sha256).hexdigest()
   if url:
    class NoRedirect(urllib.request.HTTPRedirectHandler):
     def redirect_request(self,*args,**kwargs): return None
    opener=urllib.request.build_opener(NoRedirect)
    with opener.open(urllib.request.Request(url,data=data,headers=headers),timeout=2) as response: ok=200<=response.status<300
  except Exception: ok=False
  result.append(dict(id=c['id'],ok=ok))
 return result
if testing:
 print(json.dumps(deliver('Test alert from '+socket.gethostname()+'. No application state was changed.'))); sys.exit(0)
if not settings.get('enabled',False): sys.exit(0)
issues=[]; checked_hosts=set(); disk=shutil.disk_usage('/'); used=100*disk.used/max(1,disk.total)
if used>=settings.get('diskPercent',85): issues.append(('disk','Disk space is low',str(round(used))+'% of root disk is used.',None))
with open('/proc/meminfo') as f: mem={line.split(':')[0]:int(line.split()[1]) for line in f}
free=100*mem.get('MemAvailable',mem.get('MemFree',0))/max(1,mem['MemTotal'])
if free<settings.get('memoryPressure',20): issues.append(('memory','Memory is running low',str(round(free))+'% of memory is available.',None))
r=subprocess.run(['docker','ps','-a','--format','{{json .}}'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=20)
if r.returncode: issues.append(('docker','Docker could not be observed','Check the Docker service on this server.',None))
else:
 for line in r.stdout.splitlines()[:1000]:
  c=json.loads(line); name=c.get('Names',''); labels=c.get('Labels',''); managed='com.docker.compose.project=' in labels
  if not managed and name not in (settings.get('watchContainers') or []): continue
  current=c.get('State',''); key='app:'+name
  if current not in ('running','paused'): issues.append((key,'App is not running',name+' is '+current+'.',name))
  elif 'Restarting' in c.get('Status','') or '(unhealthy)' in c.get('Status',''): issues.append((key,'App needs attention',name+' reports '+c.get('Status','')+'.',name))
  # Certificate observations use only explicit Docker web-host labels.
  hosts=re.findall(r'(?:^|,)caddy=([^,]+)',labels)
  for host in hosts:
   if len(checked_hosts)>=10 or host in checked_hosts or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}',host): continue
   checked_hosts.add(host)
   try:
    with socket.create_connection((host,443),timeout=2) as raw:
     with ssl.create_default_context().wrap_socket(raw,server_hostname=host) as tls: expires=ssl.cert_time_to_seconds(tls.getpeercert()['notAfter'])
    days=(expires-time.time())/86400
    if days<settings.get('certDays',14): issues.append(('cert:'+host,'Web certificate expires soon',host+' expires in '+str(max(0,int(days)))+' days.',name))
   except Exception: issues.append(('cert:'+host,'Web certificate could not be checked',host+' did not provide a valid certificate.',name))
now=time.time(); current={item[0] for item in issues}
for key,title,message,app in issues:
 previous=state.get(key,0)
 if now-previous < settings.get('remindMinutes',1440)*60: continue
 deliveries=deliver(socket.gethostname()+': '+title+'\n'+message)
 history.append(dict(id=int(now*1000)+len(history)%1000,severity='warning',title=title,message=message,app=app,at=datetime.datetime.now(datetime.timezone.utc).isoformat(),delivered=deliveries))
 if deliveries and all(d['ok'] for d in deliveries): state[key]=now
state={k:v for k,v in state.items() if k in current}; save('state.json',state); save('history.json',history[-100:])
""";
}
