using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace TerminalDeck.Core.Remote;

// One bounded transfer per authenticated connection. The destination callback
// reconsults CURRENT grants and rejects junctions before each write and commit.
public sealed class PhoneUploadFeatures(Func<ApprovedDevice, string?, string> destination, TimeProvider? clock = null, PhoneUploadedFiles? completed = null) : IPhoneHostWorkspace, IDisposable
{
  private sealed class Sink(string id, string directory, string? requested, string path, string temporary, long size, FileStream file, SafeFileHandle? lease, DateTimeOffset now) : IDisposable
  {
    public string Id = id, Directory = directory, Path = path, Temporary = temporary;
    public string? Requested = requested;
    public long Size = size, Received;
    public FileStream File = file;
    public IncrementalHash Hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    public DateTimeOffset Last = now;
    public void Dispose() { File.Dispose(); Hash.Dispose(); lease?.Dispose(); try { System.IO.File.Delete(Temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
  }
  private readonly object gate = new();
  private readonly Dictionary<string, Sink> sinks = [];
  private readonly TimeProvider time = clock ?? TimeProvider.System;
  private bool disposed;
  public IReadOnlyList<string> Capabilities => ["upload"];
  public bool Handles(string type) => type is "upload.begin" or "upload.data" or "upload.end" or "upload.cancel";
  public bool Permits(PhoneAccess access, string type) => access is PhoneAccess.Hoot or PhoneAccess.Work or PhoneAccess.Full;
  public ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    lock (gate)
    {
      ObjectDisposedException.ThrowIf(disposed, this);
      var id = Text(message, "id", 128);
      if (!Permits(device.Access, type)) { Drop(channel); throw new PhoneRefusal("unauthorized", "Sending files needs Work or Full control."); }
      try
      {
        if (type == "upload.cancel") { if (sinks.TryGetValue(channel, out var cancelled) && cancelled.Id == id) Drop(channel); return Reply(Failed(id, "Cancelled on the device.")); }
        if (type == "upload.begin")
        {
          if (sinks.ContainsKey(channel)) return Reply(Failed(id, "This device is already sending a file. Finish or cancel it first."));
          if (sinks.Count >= 32) return Reply(Failed(id, "This PC is receiving too many files. Try again shortly."));
          var requested = Optional(message, "dir");
          var directory = System.IO.Path.GetFullPath(destination(device, requested));
          if (!System.IO.Directory.Exists(directory)) throw new IOException("Choose an existing folder.");
          var name = SafeName(Text(message, "name", 255));
          if (!message.TryGetProperty("size", out var amount) || !amount.TryGetInt64(out var size) || size is < 1 or > 536870912) throw new PhoneRefusal("bad-message", "Choose a file between 1 byte and 512 MB.");
          var lease = Lease(directory);
          FileStream? file = null; string? temporary = null;
          try
          {
            var path = Unique(directory, name);
            temporary = System.IO.Path.Combine(directory, ".td-upload-" + Guid.NewGuid().ToString("N") + ".part");
            file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 24576, FileOptions.SequentialScan);
            sinks.Add(channel, new Sink(id, directory, requested, path, temporary, size, file, lease, time.GetUtcNow()));
            return Reply(new JsonObject { ["t"] = "upload.ready", ["id"] = id, ["path"] = path });
          }
          catch { file?.Dispose(); lease?.Dispose(); if (temporary is not null) try { File.Delete(temporary); } catch (IOException) { } throw; }
        }
        if (!sinks.TryGetValue(channel, out var sink) || sink.Id != id) return Reply(Failed(id, "There is no upload with that id."));
        if (time.GetUtcNow() - sink.Last > TimeSpan.FromMinutes(2)) throw new IOException("That upload timed out. Nothing was saved.");
        var allowed = System.IO.Path.GetFullPath(destination(device, sink.Requested));
        if (!string.Equals(allowed, sink.Directory, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new PhoneRefusal("unauthorized", "The destination grant changed. Nothing was saved.");
        sink.Last = time.GetUtcNow();
        if (type == "upload.data")
        {
          var encoded = Text(message, "data", 32768, empty: true);
          if (encoded.Length % 4 != 0 || encoded.Any(char.IsWhiteSpace)) throw new FormatException();
          var bytes = Convert.FromBase64String(encoded);
          if (bytes.Length > 24576 || sink.Received + bytes.Length > sink.Size) throw new IOException("That file sent more bytes than promised. Nothing was saved.");
          sink.File.Write(bytes); sink.Hash.AppendData(bytes); sink.Received += bytes.Length;
          return bytes.Length == 0 ? ValueTask.FromResult<IReadOnlyList<JsonObject>>([]) : Reply(new JsonObject { ["t"] = "upload.ack", ["id"] = id, ["bytes"] = bytes.Length });
        }
        if (type != "upload.end") throw new PhoneRefusal("bad-message", "Unknown upload operation.");
        var expected = Text(message, "sha256", 64);
        if (expected.Length != 64 || expected.Any(c => !char.IsAsciiHexDigit(c))) throw new FormatException();
        var digest = Convert.ToHexString(sink.Hash.GetHashAndReset()).ToLowerInvariant();
        if (sink.Received != sink.Size || !string.Equals(digest, expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("That file was incomplete or its checksum did not match. Nothing was saved.");
        sink.File.Flush(flushToDisk: true); sink.File.Dispose();
        // Move without overwrite. A concurrently-created destination wins safely.
        File.Move(sink.Temporary, sink.Path, overwrite: false);
        completed?.Remember(device, sink.Path, sink.Received, digest);
        sinks.Remove(channel); sink.Dispose();
        return Reply(new JsonObject { ["t"] = "upload.done", ["id"] = id, ["path"] = sink.Path, ["bytes"] = sink.Received, ["sha256"] = digest });
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or FormatException or PhoneRefusal)
      {
        Drop(channel); return Reply(Failed(id, ex is PhoneRefusal refusal ? refusal.Message : "The file could not be received safely. Nothing was saved."));
      }
    }
  }
  public ValueTask DisconnectedAsync(string channel) { lock (gate) Drop(channel); return ValueTask.CompletedTask; }
  public void Dispose() { lock (gate) { disposed = true; foreach (var sink in sinks.Values) sink.Dispose(); sinks.Clear(); } }
  private void Drop(string channel) { if (sinks.Remove(channel, out var sink)) sink.Dispose(); }
  private static ValueTask<IReadOnlyList<JsonObject>> Reply(JsonObject value) => ValueTask.FromResult<IReadOnlyList<JsonObject>>([value]);
  private static JsonObject Failed(string id, string message) => new() { ["t"] = "upload.failed", ["id"] = id, ["message"] = message };
  private static string? Optional(JsonElement message, string field) => message.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
  private static string Text(JsonElement message, string field, int limit, bool empty = false) => Optional(message, field) is { } value && (empty || value.Length > 0) && value.Length <= limit && !value.Any(char.IsControl) ? value : throw new PhoneRefusal("bad-message", "Invalid " + field + ".");
  private static string SafeName(string name)
  {
    if (name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '<', '>', '"', '|', '?', '*']) >= 0 || name.EndsWith('.') || name.EndsWith(' ')) throw new PhoneRefusal("bad-message", "Choose a plain file name.");
    var stem = name.Split('.')[0].ToUpperInvariant();
    if (stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsAsciiDigit(stem[3])) throw new PhoneRefusal("bad-message", "That name is reserved by Windows.");
    return name;
  }
  private static string Unique(string directory, string name)
  {
    for (var index = 0; index < 1000; index++)
    {
      var candidate = System.IO.Path.Combine(directory, index == 0 ? name : System.IO.Path.GetFileNameWithoutExtension(name) + " (" + index + ")" + System.IO.Path.GetExtension(name));
      if (!File.Exists(candidate) && !System.IO.Directory.Exists(candidate)) return candidate;
    }
    throw new IOException("No available file name.");
  }
  private static SafeFileHandle? Lease(string directory)
  {
    if (!OperatingSystem.IsWindows()) return null;
    // Omit FILE_SHARE_DELETE so a directory cannot become a junction or move
    // between authorization and commit while this transfer holds an open file.
    var handle = CreateFileW(directory, 0, 3, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
    if (handle.IsInvalid) { handle.Dispose(); throw new IOException("The upload folder could not be locked safely."); }
    return handle;
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
}
