namespace TerminalDeck.Core.Servers;

// Internal fixed-namespace capture operations. These scripts are never accepted
// as caller input or exposed through an unrestricted remote-command tool.
public static class ServerSigninScripts
{
  private static string Id(string attempt)
  { if (!Guid.TryParseExact(attempt, "N", out _)) throw new ServerRefusal("Choose a private sign-in attempt."); return attempt; }
  public static string Login(string attempt)
  {
    var id = Id(attempt);
    return """
umask 077
td_auth="/tmp/td-server-signin-ATTEMPT"
mkdir -m 700 "$td_auth" || exit 1
trap 'rm -rf -- "$td_auth"; exit 130' HUP TERM
cat > "$td_auth/open" <<'TD_BROWSER_CAPTURE'
#!/bin/sh
umask 077
[ "$#" -eq 1 ] || exit 1
printf '%s' "$1" > "$0.url.tmp" && mv -- "$0.url.tmp" "$0.url"
TD_BROWSER_CAPTURE
chmod 700 "$td_auth/open" || exit 1
PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.claude/local:$PATH"
export PATH
BROWSER="$td_auth/open" claude auth login --claudeai
td_result=$?
printf '%s' "$td_result" > "$td_auth/done.tmp" && mv -- "$td_auth/done.tmp" "$td_auth/done"
(exit "$td_result")
""".Replace("ATTEMPT", id, StringComparison.Ordinal);
  }
  public static ServerCommand Capture(string attempt) => new("python3 -c " + ServerValidation.Quote("""
import os,json,stat
p='/tmp/td-server-signin-ATTEMPT'
if os.path.lexists(p):
 s=os.lstat(p)
 if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077:raise RuntimeError('private capture unavailable')
def read(leaf,limit):
 path=p+'/'+leaf
 try:
  s=os.lstat(path)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_size>limit:raise RuntimeError('capture refused')
  with open(path) as f:return f.read(limit+1)
 except FileNotFoundError:return None
url=read('open.url',8192);done=read('done',8)
print(json.dumps(dict(address=url,done=done is not None,exitCode=int(done) if done is not None else -1)))
""".Replace("ATTEMPT", Id(attempt), StringComparison.Ordinal)), MaxOutputBytes: 16384);
  public static ServerCommand Watch(string attempt)
  {
    // The complete fixed script is generated independently of any URL. Its
    // only substitution is the already validated attempt namespace.
    var script = """
import os,json,stat,time
p='/tmp/td-server-signin-ATTEMPT'
def read(leaf,limit):
 try:
  s=os.lstat(p)
  if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077:raise RuntimeError('private capture unavailable')
  path=p+'/'+leaf;s=os.lstat(path)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_size>limit:raise RuntimeError('capture refused')
  with open(path) as f:return f.read(limit+1)
 except FileNotFoundError:return None
last=object();end=time.monotonic()+960
while time.monotonic()<end:
 url=read('open.url',8192);done=read('done',8);value=(url,done)
 if value!=last:
  print(json.dumps(dict(address=url,done=done is not None,exitCode=int(done) if done is not None else -1)),flush=True);last=value
 if done is not None:break
 time.sleep(0.2)
""".Replace("ATTEMPT", Id(attempt), StringComparison.Ordinal);
    return new("python3 -u -c " + ServerValidation.Quote(script), MaxOutputBytes: 65536);
  }
  public static ServerCommand Cleanup(string attempt) => new("python3 -c " + ServerValidation.Quote("import os,shutil,stat; p='/tmp/td-server-signin-" + Id(attempt) + "'; s=os.lstat(p) if os.path.lexists(p) else None; assert s is None or (stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid()); shutil.rmtree(p) if s else None"), MaxOutputBytes: 1024);
}
