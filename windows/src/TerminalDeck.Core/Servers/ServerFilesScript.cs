using System.Text.Json;

namespace TerminalDeck.Core.Servers;

// The remote helper walks directory handles with O_NOFOLLOW. A symlink swapped
// after the folder check cannot turn an allowed path into a different folder.
public static class ServerFilesScript
{
  public const int TransferLimit = 8 * 1024 * 1024;
  public static ServerCommand Make(SavedServer server, string op, string path, string? data = null, string? name = null, int offset = 0)
  {
    if (offset < 0 || offset > int.MaxValue - 1000) throw new ServerRefusal("Choose a valid file page.");
    ServerValidation.Path(path);
    if (server.Access.Folders.Length == 0) throw new ServerRefusal("Choose an allowed folder on the Access page first.");
    if (!server.Access.Folders.Any(root => path == root.TrimEnd('/') || path.StartsWith(root.TrimEnd('/') + "/", StringComparison.Ordinal)))
      throw new ServerRefusal("This path is outside the allowed folders.");
    if (op != "list" && Sensitive(path)) throw new ServerRefusal("Key, password and environment files cannot be opened here.");
    if (name is not null && (name.Length is < 1 or > 255 || name is "." or ".." || name.IndexOfAny(['/', '\\']) >= 0 || name.Any(char.IsControl) || Sensitive(name)))
      throw new ServerRefusal("Choose a plain file name.");
    return new("python3 -c " + ServerValidation.Quote(Script), JsonSerializer.Serialize(new { op, path, roots = server.Access.Folders, data, name, offset }), op == "download" ? TransferLimit * 2 : 524288);
  }
  public static bool Sensitive(string path) => path.Split('/').Any(p => p.Equals(".ssh", StringComparison.OrdinalIgnoreCase) ||
    p.Equals(".aws", StringComparison.OrdinalIgnoreCase) || p.Equals(".gnupg", StringComparison.OrdinalIgnoreCase) ||
    p.StartsWith(".env", StringComparison.OrdinalIgnoreCase) || p.Equals("credentials", StringComparison.OrdinalIgnoreCase) ||
    p.Equals("shadow", StringComparison.OrdinalIgnoreCase) || p.Equals("passwd", StringComparison.OrdinalIgnoreCase) ||
    p.StartsWith("id_", StringComparison.OrdinalIgnoreCase) || new[] { ".pem", ".key", ".pfx", ".p12", ".kdbx" }.Any(ext => p.EndsWith(ext, StringComparison.OrdinalIgnoreCase)));
  private const string Script = """
import os,sys,json,base64,stat
q=json.load(sys.stdin)
p=q['path']; roots=sorted(q['roots'],key=len,reverse=True)
r=next((r.rstrip('/') for r in roots if p==r.rstrip('/') or p.startswith(r.rstrip('/')+'/')),None)
if r is None: raise Exception('Folder not allowed')
parts=[x for x in p.split('/') if x]
if any(x in ('.','..') for x in parts): raise Exception('Invalid path')
fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
try:
 for part in parts[:-1]:
  n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd); os.close(fd); fd=n
 leaf=parts[-1] if parts else '.'
 op=q['op']
 if op=='list':
  d=os.open(leaf,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
  try:
   entries=[]
   names=sorted(os.listdir(d))
   offset=q.get('offset',0)
   for name in names[offset:offset+1000]:
    s=os.stat(name,dir_fd=d,follow_symlinks=False)
    entries.append(dict(name=name,path=p.rstrip('/')+'/'+name,kind='folder' if stat.S_ISDIR(s.st_mode) else 'link' if stat.S_ISLNK(s.st_mode) else 'file' if stat.S_ISREG(s.st_mode) else 'special',size=s.st_size,modified=s.st_mtime))
   print(json.dumps(dict(path=p,entries=entries,more=len(names)>offset+1000,offset=offset)))
  finally: os.close(d)
 elif op in ('read','download'):
  f=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
  try:
   if not stat.S_ISREG(os.fstat(f).st_mode): raise Exception('Choose a regular file')
   limit=262144 if op=='read' else 8388608
   with os.fdopen(f,'rb',closefd=False) as stream: b=stream.read(limit+1)
   if op=='download' and len(b)>limit: raise Exception('File exceeds transfer limit')
   print(json.dumps(dict(path=p,base64=base64.b64encode(b[:limit]).decode(),truncated=len(b)>limit)))
  finally: os.close(f)
 elif op=='upload':
  b=base64.b64decode(q['data'],validate=True)
  if len(b)>8388608: raise Exception('File exceeds transfer limit')
  f=os.open(leaf,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
  try:
   with os.fdopen(f,'wb',closefd=False) as stream: stream.write(b); stream.flush(); os.fsync(f)
  except BaseException:
   os.unlink(leaf,dir_fd=fd); raise
  finally: os.close(f)
  print('{}')
 elif op=='rename':
  # link+unlink gives no-overwrite semantics. Directory renaming is deliberately absent.
  s=os.stat(leaf,dir_fd=fd,follow_symlinks=False)
  if not stat.S_ISREG(s.st_mode): raise Exception('Choose a regular file')
  os.link(leaf,q['name'],src_dir_fd=fd,dst_dir_fd=fd,follow_symlinks=False); os.unlink(leaf,dir_fd=fd); print('{}')
 elif op=='delete':
  s=os.stat(leaf,dir_fd=fd,follow_symlinks=False)
  if not stat.S_ISREG(s.st_mode): raise Exception('Choose a regular file')
  os.unlink(leaf,dir_fd=fd); print('{}')
 else: raise Exception('Unknown file action')
finally: os.close(fd)
""";
}
