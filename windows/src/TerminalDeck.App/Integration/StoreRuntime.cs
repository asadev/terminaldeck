using System.Text.Json;
using TerminalDeck.Core.Store;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private AppStoreService? appStore;
  public AppStoreService AppStore => appStore ?? throw new InvalidOperationException("The Store browser connection is not ready yet.");
  public void InitializeStoreExtensions(IStoreBrowserExtensions browser, IStoreAuthorizer authorizer)
  {
    if (appStore is not null) return;
    appStore = new(new TerminalDeck.Core.Storage.JsonStateStore<StoreLedger>(Root, "app-store"), new AppStoreInstaller(Root.DirectoryPath, new HttpClient(), browser, new CommunityStoreOperations(Root.DirectoryPath, Mcp, value => Routines.Save(value), id => Routines.Remove(id), getRoutine: id => Routines.List().SingleOrDefault(r => r.Id == id))), authorizer);
    appStore.MergeCatalog(NativeStoreStock.BuiltIns.Concat(McpStoreStock.Read()));
  }
  private void InitializeStoreTools()
  {
    Door.Register("store.catalog", async (context, args, ct) =>
    {
      await context.EnsureCurrentAsync(ct); using var http = new HttpClient();
      return JsonSerializer.SerializeToElement(new { entries = await AppStore.ImportCatalogAsync(args.GetProperty("url").GetString()!, args.GetProperty("sha256").GetString()!, http, ct) });
    });
    Door.Register("store.browse", (context, args, ct) =>
    {
      string? Text(string key) => args.TryGetProperty(key, out var value) ? value.GetString() : null;
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(AppStore.Browse(Text("department"), Text("query") ?? "", Text("category"), Text("cost"), args.TryGetProperty("installed", out var installed) ? installed.GetBoolean() : null)));
    });
    Door.Register("store.change", async (context, args, ct) =>
    {
      await context.EnsureCurrentAsync(ct);
      var options = args.TryGetProperty("options", out var input) ? JsonSerializer.Deserialize<StoreInstallOptions>(input, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) : null;
      if (options?.Folder is { } folder) context.Require("folders", folder);
      return JsonSerializer.SerializeToElement(await AppStore.ChangeAsync(args.GetProperty("id").GetString()!, args.GetProperty("action").GetString()!, ct, context.EnsureCurrentAsync, options));
    });
    Door.Register("docker.catalog", (context, args, ct) => ValueTask.FromResult(JsonSerializer.SerializeToElement(ServerService.AppCatalog)));
    Door.Register("docker.configure", async (context, args, ct) =>
    {
      var id = args.GetProperty("serverId").GetString()!; context.Require("servers", id); await context.EnsureCurrentAsync(ct);
      var caller = new ServerCaller(context.Grant.CallerId, EnsureCurrent: context.EnsureCurrentAsync);
      var service = Servers as ServerService ?? throw new InvalidOperationException("The server connection is not ready.");
      var draft = JsonSerializer.Deserialize<DockerAppDraft>(args.GetProperty("draft"), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
      var action = args.GetProperty("action").GetString()!;
      return action == "preview" ? JsonSerializer.SerializeToElement(service.PreviewApp(id, draft, caller)) : JsonSerializer.SerializeToElement(await service.DeployAppAsync(id, draft, action, caller, ct));
    });
  }
}
