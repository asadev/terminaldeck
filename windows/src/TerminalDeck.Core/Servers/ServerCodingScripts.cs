namespace TerminalDeck.Core.Servers;

internal static class ServerCodingScripts
{
  public const string Inventory = """
import os,json,shutil,subprocess,tempfile,re,resource
home=os.path.expanduser('~')
extra=[home+'/.local/bin',home+'/bin',home+'/.npm-global/bin',home+'/.claude/local']
node=home+'/.nvm/versions/node'
if os.path.isdir(node): extra += [node+'/'+n+'/bin' for n in sorted(os.listdir(node))[-16:]]
path=os.pathsep.join(extra+[os.environ.get('PATH','')]); env=dict(os.environ,PATH=path)
def run(args):
 try:
  with tempfile.TemporaryFile() as out:
   p=subprocess.Popen(args,stdout=out,stderr=subprocess.STDOUT,env=env,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_FSIZE,(1048576,1048576)))
   try: code=p.wait(timeout=4)
   except subprocess.TimeoutExpired: p.kill();p.wait();return -1,''
   out.seek(0); return code,out.read(16384).decode('utf-8','replace')
 except OSError:return -1,''
free=shutil.disk_usage(home).free; memory=None
try:
 with open('/proc/meminfo') as f:
  for line in f:
   if line.startswith('MemAvailable:'): memory=int(line.split()[1])*1024
except OSError:pass
rows=[]
for provider,name,needed in [('claude','Claude Code',350),('codex','Codex CLI',330),('gemini','Gemini CLI',130)]:
 binary=shutil.which(provider,path=path) or ''; version=''; signin='unknown'; why=None
 if binary:
  code,text=run([binary,'--version']); version=text.splitlines()[0][:200] if code==0 and text.splitlines() else 'Version could not be read'
  if provider=='claude':
   code,text=run([binary,'auth','status','--json'])
   try:
    status=json.loads(text); logged=status.get('loggedIn'); signin='yes' if logged is True else 'no' if logged is False else 'unknown'
   except (ValueError,AttributeError):pass
  elif provider=='codex':
   code,text=run([binary,'login','status']); text=text.lower()
   if 'not logged in' in text or 'not signed in' in text:signin='no'
   elif 'logged in' in text:signin='yes'
 npm=shutil.which('npm',path=path)
 if provider=='claude' and not (shutil.which('curl',path=path) or shutil.which('wget',path=path)):why='This server needs curl or wget before Claude Code can be installed.'
 elif provider!='claude' and not npm:why='This server needs Node and npm before this coding AI can be installed.'
 elif provider=='claude' and memory is not None and memory<512*1024*1024:why='Claude Code needs about 512 MB of available memory during installation.'
 elif free<needed*1024*1024:why='There is not enough free space in this SSH user home folder.'
 marker=home+'/.local/state/terminaldeck/coding-ai/'+provider+'.json'; ours=False
 try:
  with open(marker) as f: receipt=json.loads(f.read(4097))
  ours=receipt=={'provider':provider,'installedHere':True} and binary==home+'/.local/bin/'+provider
 except (OSError,ValueError):pass
 rows.append(dict(provider=provider,name=name,installed=bool(binary),path=binary,version=version,signIn=signin,canInstall=why is None,why=why,canRemove=ours,canSignIn=bool(binary),canSignOut=bool(binary) and provider!='gemini'))
print(json.dumps(rows))
""";
  private const string Environment = """
td_original_path="$PATH"
PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.claude/local"
for td_node in "$HOME"/.nvm/versions/node/*/bin; do [ ! -d "$td_node" ] || PATH="$PATH:$td_node"; done
PATH="$PATH:$td_original_path"; export PATH
""";
  public static string Login(string provider, bool signOut) => Environment + "\n" + provider + (signOut ? provider == "claude" ? " auth logout" : " logout" : provider == "claude" ? " auth login --claudeai" : provider == "codex" ? " login --device-auth" : "");
  public static string Install(string provider)
  {
    var command = provider switch
    {
      "claude" => "if command -v curl >/dev/null 2>&1; then curl --proto '=https' --tlsv1.2 -fsSL --max-time 120 https://claude.ai/install.sh -o \"$td_script\"; else wget --https-only -T 120 -qO \"$td_script\" https://claude.ai/install.sh; fi && bash \"$td_script\"",
      "codex" => "npm install -g --prefix \"$HOME/.local\" @openai/codex",
      "gemini" => "npm install -g --prefix \"$HOME/.local\" @google/gemini-cli",
      _ => throw new ServerRefusal("Choose a supported coding AI.")
    };
    return Environment + "\n" + """
umask 077
td_before=0
command -v PROVIDER >/dev/null 2>&1 && td_before=1
[ ! -e "$HOME/.local/bin/PROVIDER" ] || td_before=1
[ ! -d "$HOME/PACKAGE_PATH" ] || td_before=1
td_script=$(mktemp) || exit 1
trap 'rm -f "$td_script"' EXIT
(
INSTALL
) || exit $?
"$HOME/.local/bin/PROVIDER" --version || exit $?
if [ "$td_before" = 0 ]; then
  mkdir -p "$HOME/.local/state/terminaldeck/coding-ai" || exit 1
  printf '%s\n' '{"provider":"PROVIDER","installedHere":true}' > "$HOME/.local/state/terminaldeck/coding-ai/PROVIDER.json"
fi
""".Replace("PROVIDER", provider, StringComparison.Ordinal).Replace("INSTALL", command, StringComparison.Ordinal).Replace("PACKAGE_PATH", provider == "claude" ? ".local/share/claude/versions" : provider == "codex" ? ".local/lib/node_modules/@openai/codex" : ".local/lib/node_modules/@google/gemini-cli", StringComparison.Ordinal);
  }
  public static string Remove(string provider)
  {
    var package = provider == "codex" ? "@openai/codex" : "@google/gemini-cli";
    var removal = provider == "claude" ? "rm -f -- \"$HOME/.local/bin/claude\"; rm -rf -- \"$HOME/.local/share/claude/versions\"" : "npm uninstall -g --prefix \"$HOME/.local\" " + package;
    return Environment + "\npython3 -c " + ServerValidation.Quote("import os,json,sys; p=os.path.expanduser('~/.local/state/terminaldeck/coding-ai/" + provider + ".json'); r=json.load(open(p)); sys.exit(0 if r=={'provider':'" + provider + "','installedHere':True} else 1)") + " || exit 1\n" + removal + " && rm -f -- \"$HOME/.local/state/terminaldeck/coding-ai/" + provider + ".json\"";
  }
}
