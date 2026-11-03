using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Remote;

public sealed class PhoneUploadedFiles
{
  private sealed record Receipt(string Device, string Path, long Size, string Hash);
  private readonly object gate = new();
  private readonly Dictionary<string, Receipt> receipts = new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
  public void Remember(ApprovedDevice device, string path, long size, string hash)
  {
    lock (gate)
    {
      if (receipts.Count >= 2048) receipts.Remove(receipts.Keys.First());
      receipts[path] = new(device.Id, path, size, hash);
    }
  }
  public static string[] Paths(JsonElement message)
  {
    if (!message.TryGetProperty("files", out var files)) return [];
    if (files.ValueKind != JsonValueKind.Array || files.GetArrayLength() > 4) throw new PhoneRefusal("bad-message", "Send up to four uploaded attachments.");
    var paths = files.EnumerateArray().Select(f => f.ValueKind == JsonValueKind.String && f.GetString() is { Length: > 0 and <= 4096 } value && !value.Any(char.IsControl) ? value : throw new PhoneRefusal("bad-message", "Choose an uploaded attachment.")).ToArray();
    if (paths.Distinct(StringComparer.Ordinal).Count() != paths.Length) throw new PhoneRefusal("bad-message", "Choose each attachment once.");
    return paths;
  }
  public async ValueTask<ChatAttachmentData[]> ReadAsync(ApprovedDevice device, IReadOnlyList<string> paths, Func<ApprovedDevice, string, bool> allowed, CancellationToken ct)
  {
    if (device.Access is not (PhoneAccess.Full or PhoneAccess.Work or PhoneAccess.Hoot)) throw new PhoneRefusal("unauthorized", "This phone cannot send attachments.");
    if (paths.Count > 4) throw new PhoneRefusal("bad-message", "Send up to four uploaded attachments.");
    var result = new List<ChatAttachmentData>(); long total = 0;
    foreach (var path in paths)
    {
      Receipt receipt;
      lock (gate) receipt = receipts.TryGetValue(path, out var found) && found.Device == device.Id ? found : throw new PhoneRefusal("unauthorized", "This file was not uploaded by this phone.");
      if (receipt.Size > 8 * 1024 * 1024 || (total += receipt.Size) > 24 * 1024 * 1024) throw new PhoneRefusal("bad-message", "These chat attachments are too large.");
      void Check()
      {
        if (!allowed(device, path) || !string.Equals(PhoneWorkspacePaths.Resolve(path), Path.GetFullPath(path), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
          throw new PhoneRefusal("unauthorized", "This phone no longer has access to the uploaded file.");
      }
      Check();
      await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
      if (stream.Length != receipt.Size) throw new PhoneRefusal("unauthorized", "The uploaded file changed. Upload it again.");
      var bytes = new byte[checked((int)receipt.Size)]; await stream.ReadExactlyAsync(bytes, ct);
      Check();
      if (!string.Equals(Convert.ToHexString(SHA256.HashData(bytes)), receipt.Hash, StringComparison.OrdinalIgnoreCase)) throw new PhoneRefusal("unauthorized", "The uploaded file changed. Upload it again.");
      result.Add(ChatAttachmentData.Read(Path.GetFileName(path), bytes));
    }
    return result.ToArray();
  }
}
