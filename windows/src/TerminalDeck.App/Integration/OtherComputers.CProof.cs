using System.Text.Json;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  internal static OtherComputersService CProof(AppDataRoot root)
  {
    if (!File.Exists(Path.Combine(root.DirectoryPath, ".c-parity-proof"))) throw new InvalidOperationException("An explicit C scratch marker is required.");
    var service = new OtherComputersService(root);
    service.views["fixture"] = new("fixture", "Studio Mac", "macos", "Online", null, ["controls", "account", "usage", "rename"], []);
    service.AcceptSnapshot("fixture", JsonSerializer.SerializeToElement(new
    {
      t = "welcome", sessions = new[] { new { id = "fixture-session", title = "Review the release", cwd = "/Projects/Website", provider = "codex", status = "waiting" } }
    }));
    return service;
  }
}
