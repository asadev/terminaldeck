namespace TerminalDeck.Core.Servers;

internal static class ServerWebsiteScripts
{
  public const string Inventory = """
import os,json,re,shutil,subprocess,tempfile,glob,resource
os.environ['PATH']=os.environ.get('PATH','')+':/usr/local/sbin:/usr/sbin:/sbin'

def run(args):
 try:
  with tempfile.TemporaryFile() as out:
   p=subprocess.Popen(args,stdout=out,stderr=subprocess.STDOUT,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_FSIZE,(2097152,2097152)))
   try:code=p.wait(timeout=8)
   except subprocess.TimeoutExpired:p.kill();p.wait();return None
   if code:return None
   out.seek(0);return out.read(2097152).decode('utf-8','replace')
 except OSError:return None
listeners=run(['ss','-H','-ltn'])
if listeners is None:listeners=run(['netstat','-ltn'])
ports=set()
for line in (listeners or '').splitlines():
 for address in line.split():
  m=re.search(r':(80|443)$',address)
  if m:ports.add(int(m.group(1)))
web=next((name for name in ['caddy','nginx','apache2','httpd'] if shutil.which(name)),None)
names=set();text=None
if web=='caddy':
 try:
  with open('/etc/caddy/Caddyfile') as f:text=f.read(2097152)
 except OSError:pass
 if text is not None:
  for line in text.splitlines():
   if line and not line[0].isspace() and not line.startswith('#') and line.rstrip().endswith('{'):
    for value in line.rsplit('{',1)[0].split(','):names.add(value.strip())
elif web=='nginx':
 text=run(['nginx','-T'])
 if text is None:
  parts=[];total=0
  for file in sorted(glob.glob('/etc/nginx/sites-enabled/*')+glob.glob('/etc/nginx/conf.d/*.conf'))[:256]:
   try:
    with open(file) as f:part=f.read(min(262144,2097152-total))
    parts.append(part);total+=len(part)
   except OSError:continue
   if total>=2097152:break
  if parts:text='\n'.join(parts)
 if text is not None:
  for match in re.finditer(r'(?m)^\s*server_name\s+([^;\n]+);',text):names.update(match.group(1).split())
elif web:
 text=run([web+'ctl','-S'])
 if text is not None:
  for line in text.splitlines():
   fields=line.split()
   if 'namevhost' in fields:
    at=fields.index('namevhost')
    if at+1<len(fields):names.add(fields[at+1])
if web and text is None:raise RuntimeError('This SSH sign-in cannot read the web server settings.')
rows=[]
for name in sorted(names):
 if name in ('_','') or len(name)>253 or not re.fullmatch(r'[A-Za-z0-9*.-]+',name):continue
 url=None
 if '*' not in name:
  if 443 in ports:url='https://'+name
  elif 80 in ports:url='http://'+name
 rows.append(dict(id='site:'+name,name=name,detail='Served by '+str(web),url=url))
 if len(rows)==100:break
print(json.dumps(rows))
""";
}
