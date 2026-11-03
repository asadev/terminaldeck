using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Servers;

public sealed record DockerAppTemplate(string Id, string Name, string Department, string Description, string Image, int ContainerPort, string[] Environment);
public sealed record DockerAppDraft(string Name, string Directory, string Compose, string Environment, string? Repository = null, string? Branch = null);
public sealed record DockerAppPlan(string ServerId, string Name, string Directory, string Compose, string Environment, string? Repository, string? Branch);
public sealed record DockerAppDeployment(string Name, string Action, string Output, DateTimeOffset FinishedAt);
public sealed partial class ServerService
{
  public static IReadOnlyList<DockerAppTemplate> AppCatalog { get; } =
  [new("nginx", "Web server", "Web", "Serve a website with Nginx.", "nginx:stable-alpine", 80, []),
   new("postgres", "PostgreSQL", "Databases", "A PostgreSQL database with persistent storage.", "postgres:17-alpine", 5432, ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]),
   new("redis", "Redis", "Databases", "An in-memory data store.", "redis:7-alpine", 6379, []),
   new("custom", "Docker image", "Custom", "Use your own image or edit the Compose configuration.", "", 0, [])];
  public static DockerAppDraft FromTemplate(string template, string name, string directory, int hostPort)
  {
    var item = AppCatalog.SingleOrDefault(t => t.Id == template) ?? throw new ServerRefusal("Choose an app template.");
    AppName(name); ServerValidation.Path(directory); if (hostPort is < 1 or > 65535 || item.Image.Length == 0) throw new ServerRefusal("Choose an image template and a host port.");
    var environment = string.Join('\n', item.Environment.Select(key => key + "=")) + "\n";
    // Compose also accepts JSON, so all values remain data rather than YAML expression fragments.
    var service = new Dictionary<string, object?> { ["image"] = item.Image, ["restart"] = "unless-stopped", ["ports"] = new[] { hostPort + ":" + item.ContainerPort }, ["env_file"] = new[] { ".env" } };
    if (template == "postgres") service["volumes"] = new[] { "data:/var/lib/postgresql/data" };
    var compose = JsonSerializer.Serialize(new { services = new Dictionary<string, object> { [name] = service }, volumes = template == "postgres" ? new Dictionary<string, object> { ["data"] = new { } } : [] }, new JsonSerializerOptions { WriteIndented = true });
    return new(name, directory, compose, environment);
  }
  public DockerAppPlan PreviewApp(string id, DockerAppDraft draft, ServerCaller caller)
  {
    var server = Get(id, caller); ServerValidation.CanChange(server, caller); AppName(draft.Name);
    if (server.ShownApps is not null && !server.ShownApps.Contains(draft.Name, StringComparer.Ordinal)) throw new ServerRefusal("This app is hidden by this server’s shown-app filter."); ServerValidation.Path(draft.Directory);
    if (!server.Access.Folders.Any(p => draft.Directory == p || draft.Directory.StartsWith(p.TrimEnd('/') + "/", StringComparison.Ordinal))) throw new ServerRefusal("Choose an app directory within this server's allowed Files folders.");
    if (string.IsNullOrWhiteSpace(draft.Compose) || draft.Compose.Length > 1024 * 1024 || draft.Environment.Length > 256 * 1024 || draft.Compose.Contains('\0') || draft.Environment.Contains('\0')) throw new ServerRefusal("Enter a bounded Compose configuration and environment.");
    if (draft.Repository is not null && (!Uri.TryCreate(draft.Repository, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo))) throw new ServerRefusal("Use a public HTTPS repository URL without credentials.");
    if (draft.Branch is not null && !Regex.IsMatch(draft.Branch, "^[a-zA-Z0-9][a-zA-Z0-9/_.-]{0,120}$")) throw new ServerRefusal("Enter a repository branch without shell characters.");
    return new(id, draft.Name, draft.Directory, draft.Compose, draft.Environment, draft.Repository, draft.Branch);
  }
  public async ValueTask<DockerAppDeployment> DeployAppAsync(string id, DockerAppDraft draft, string action, ServerCaller caller, CancellationToken ct = default)
  {
    var plan = PreviewApp(id, draft, caller);
    if (action is not ("create" or "update" or "validate" or "pull" or "start" or "stop" or "restart" or "remove")) throw new ServerRefusal("Choose a Compose app action.");
    string output = "";
    await ChangeAsync(id, caller, action + " Docker app", draft.Name + " in " + draft.Directory + "\n" + ServerText.Mask(draft.Compose) + "\nEnvironment values are private.", false, action == "remove", async server =>
    {
      _ = PreviewApp(id, draft, caller);
      var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(plan));
      var script = "python3 -c " + ServerValidation.Quote(PythonDeployment) + " " + ServerValidation.Quote(payload) + " " + ServerValidation.Quote(action);
      output = ServerText.Mask((await RunAsync(server, new(script, MaxOutputBytes: 1024 * 1024), ct)).Output);
    }, ct);
    return new(draft.Name, action, output, DateTimeOffset.UtcNow);
  }
  public async ValueTask<DockerAppDraft> ReadAppConfigurationAsync(string id, string name, string directory, ServerCaller caller, CancellationToken ct = default)
  {
    AppName(name); ServerValidation.Path(directory); var server = Get(id, caller);
    if (server.ShownApps is not null && !server.ShownApps.Contains(name, StringComparer.Ordinal)) throw new ServerRefusal("This app is hidden by this server’s shown-app filter.");
    if (!server.Access.Folders.Any(p => directory == p || directory.StartsWith(p.TrimEnd('/') + "/", StringComparison.Ordinal))) throw new ServerRefusal("Choose an allowed app folder.");
    var content = await ReadAsync(id, directory.TrimEnd('/') + "/compose.yaml", caller, ct);
    if (content.Truncated) throw new IOException("The Compose file exceeds the transfer limit.");
    // Environment values are intentionally read separately through Files, not exposed in app lists.
    return new(name, directory, Encoding.UTF8.GetString(Convert.FromBase64String(content.Base64)), "");
  }
  private static void AppName(string name) { if (!Regex.IsMatch(name, "^[a-z][a-z0-9-]{1,62}$")) throw new ServerRefusal("Use 2–63 lowercase letters, digits or hyphens for the app name."); }
  private const string PythonDeployment = """
import base64,json,os,pathlib,subprocess,sys,tempfile
p=json.loads(base64.b64decode(sys.argv[1])); action=sys.argv[2]; root=pathlib.Path(p['Directory'])
# Resolve existing ancestors before creating anything; reject symlinks rather than following them.
for part in [root,*root.parents]:
 if part.is_symlink(): raise RuntimeError('Linked app directories are not allowed')
if action=='create' and root.exists(): raise RuntimeError('That app directory exists. Read its configuration and choose update.')
if action not in ['create','validate'] and not root.is_dir(): raise RuntimeError('That app directory is missing.')
if action=='create':
 if p.get('Repository'):
  args=['git','clone','--depth','1']
  if p.get('Branch'): args+=['--branch',p['Branch']]
  subprocess.run(args+['--',p['Repository'],str(root)],check=True)
 else: root.mkdir(parents=True,exist_ok=False)
compose=root/'compose.yaml'; env=root/'.env'
for file in [compose,env]:
 if file.is_symlink(): raise RuntimeError('Linked configuration files are not allowed')
# Validate a proposed configuration before replacing the live configuration.
if action in ['create','update','validate']:
 with tempfile.TemporaryDirectory(prefix='.deck-review-',dir=root if root.is_dir() else None) as temporary:
  staged=pathlib.Path(temporary); (staged/'compose.yaml').write_text(p['Compose']); (staged/'.env').write_text(p['Environment'] if p['Environment'] or not env.is_file() else env.read_text()); os.chmod(staged/'.env',0o600)
  subprocess.run(['docker','compose','--project-directory',str(staged),'-p',p['Name'],'-f',str(staged/'compose.yaml'),'config','--quiet'],check=True)
 if action=='validate': sys.exit(0)
 for file,text in [(compose,p['Compose']),(env,p['Environment'])]:
  if file==env and action=='update' and not text: continue
  fd,tmp=tempfile.mkstemp(prefix='.deck-',dir=root)
  try:
   os.fchmod(fd,0o600); os.write(fd,text.encode()); os.fsync(fd); os.close(fd); os.replace(tmp,file)
  finally:
   if os.path.exists(tmp): os.unlink(tmp)
args=['docker','compose','--project-directory',str(root),'-p',p['Name'],'-f',str(compose)]
commands={'create':['up','-d'],'update':['up','-d','--build'],'pull':['pull'],'start':['up','-d'],'stop':['stop'],'restart':['restart'],'remove':['down']}
subprocess.run(args+commands[action],check=True)
""";
}
