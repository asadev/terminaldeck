using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Remote;

public sealed partial class PhoneConnectedFeatures
{
  private sealed record ListedFile(string Device, string Project, string Root, string Artifact, string Relative, string Token, long Bytes, DateTime Creation, DateTime Written);
  private readonly object previewGate = new();
  private readonly Dictionary<string, ListedFile> listedFiles = new();
  private Func<string, ApprovedDevice?>? currentDevice;
  public void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publish, Func<string, ApprovedDevice?> current) => currentDevice = current;
  private string RememberArtifact(ApprovedDevice device, string root, ReceiverArtifact artifact, string file)
  {
    var info = new FileInfo(file);
    var stamp = artifact.Id + "|" + artifact.RelPath + "|" + info.Length + "|" + info.CreationTimeUtc.Ticks + "|" + info.LastWriteTimeUtc.Ticks;
    var token = device.Platform == "web" ? "#" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(stamp))).ToLowerInvariant()[..24] : Token(artifact);
    var project = VisibleProjects(device).FirstOrDefault(p => p.Folders.Any(f => Same(f, root))) ?? throw new PhoneRefusal("unauthorized", "This output is outside the shared project.");
    lock (previewGate)
    {
      var key = device.Id + "|" + root + "|" + token;
      if (listedFiles.Count >= 2048 && !listedFiles.ContainsKey(key)) listedFiles.Remove(listedFiles.Keys.First());
      listedFiles[key] = new(device.Id, project.Id, root, artifact.Id, artifact.RelPath, token, info.Length, info.CreationTimeUtc, info.LastWriteTimeUtc);
    }
    return token;
  }
  private async ValueTask<JsonObject> PreviewBytes(string channel, ApprovedDevice device, JsonElement request, CancellationToken ct)
  {
    if (Text(request, "t") == "panel.act") throw new PhoneRefusal("bad-message", "Read preview chunks with panel.read.");
    var root = Required(request, "path"); var token = Required(request, "preview");
    if (token.Length > 128) throw new PhoneRefusal("bad-message", "Choose a listed output token.");
    ListedFile receipt;
    lock (previewGate) receipt = listedFiles.TryGetValue(device.Id + "|" + root + "|" + token, out var value) ? value : throw new PhoneRefusal("unauthorized", "Read this project's artifact list before requesting its preview.");
    long at = 0; var max = 32768;
    if (request.TryGetProperty("at", out var a) && (a.ValueKind != JsonValueKind.Number || !a.TryGetInt64(out at) || at < 0)) throw new PhoneRefusal("bad-message", "Choose a nonnegative preview offset.");
    if (request.TryGetProperty("max", out var m) && (m.ValueKind != JsonValueKind.Number || !m.TryGetInt32(out max) || max is < 1 or > 32768)) throw new PhoneRefusal("bad-message", "Read up to 32,768 preview bytes at once.");
    if (at > receipt.Bytes) throw new PhoneRefusal("bad-message", "That preview offset is beyond the output.");
    string Check()
    {
      var now = currentDevice is null ? device : currentDevice(channel) ?? throw new PhoneRefusal("unauthorized", "This device is no longer connected.");
      if (now.Id != receipt.Device || now.Access != PhoneAccess.Full || !VisibleProjects(now).Any(p => p.Id == receipt.Project && p.Folders.Any(f => Same(f, receipt.Root)))) throw new PhoneRefusal("unauthorized", "This project is no longer shared with this device.");
      if (!artifacts.List(receipt.Root, receipt.Relative).Any(a => a.Id == receipt.Artifact && a.RelPath == receipt.Relative)) throw new PhoneRefusal("unauthorized", "This output is no longer in the project's artifact index.");
      var file = ReceiverArtifacts.SafePath(receipt.Root, receipt.Relative); var info = new FileInfo(file);
      if ((info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0 || info.Length != receipt.Bytes || info.CreationTimeUtc != receipt.Creation || info.LastWriteTimeUtc != receipt.Written) throw new PhoneRefusal("unavailable", "The output changed. Refresh the artifact list before previewing it.");
      return file;
    }
    var path = Check();
    // Deny concurrent write/delete on Windows for the lifetime of this chunk.
    await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 32768, true);
    if (stream.Length != receipt.Bytes) throw new PhoneRefusal("unavailable", "This output changed while opening it.");
    stream.Position = at; var bytes = new byte[(int)Math.Min(max, receipt.Bytes - at)]; await stream.ReadExactlyAsync(bytes, ct);
    _ = Check();
    var next = at + bytes.Length;
    var frame = new JsonObject { ["t"] = "panel.rows", ["panel"] = "artifacts", ["path"] = root, ["view"] = Text(request, "scope"), ["rows"] = new JsonArray(), ["actions"] = new JsonArray(),
      ["preview"] = new JsonObject { ["token"] = token, ["name"] = receipt.Relative, ["kind"] = PhoneArtifactServer.Kind(path), ["mime"] = PhoneArtifactServer.Media(path), ["encoding"] = "base64", ["data"] = Convert.ToBase64String(bytes), ["offset"] = at, ["next"] = next, ["total"] = receipt.Bytes, ["done"] = next == receipt.Bytes } };
    // JSON escaping can expand base64's plus signs. Honor the frame budget
    // even for adversarial binary contents, while advancing by actual bytes.
    while (Encoding.UTF8.GetByteCount(frame.ToJsonString()) > PhonePanelPagination.MaximumBytes - 1024)
    {
      bytes = bytes[..(bytes.Length / 2)]; next = at + bytes.Length;
      if (bytes.Length == 0) throw new PhoneRefusal("unavailable", "This output name is too large to preview safely.");
      frame["preview"]!["data"] = Convert.ToBase64String(bytes); frame["preview"]!["next"] = next; frame["preview"]!["done"] = next == receipt.Bytes;
    }
    return frame;
  }
}
