using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.Platform.Windows.Receiver;

public sealed record WindowsReceiverPreferences(bool Clipboard = false, bool Browser = false, int Port = 0);

public sealed class WindowsReceiverIntake : IReceiverIntakeSettings, IAsyncDisposable
{
  private readonly IReceiver receiver;
  private readonly WindowsReceiverData data;
  private readonly IStateStore<WindowsReceiverPreferences> preferences;
  private readonly WindowsCredentialStore secrets;
  private readonly string credentialName;
  private readonly string clipboardSource;
  private readonly string browserSource;
  private readonly Func<Func<Task>, Task> onUi;
  private readonly SemaphoreSlim gate = new(1, 1);
  private WindowsReceiverPreferences current = new();
  private ReceiverHttpIntake? http;
  private bool readingClipboard;
  private bool disposed;
  public event Action<string>? Outcome;
  public ReceiverIntakeStatus Status => new(current.Clipboard, http is not null, http?.Port);
  public WindowsReceiverIntake(AppDataRoot root, IReceiver receiver, WindowsReceiverData data, string clipboardSource,
    string browserSource, Func<Func<Task>, Task> onUi)
  {
    this.receiver = receiver; this.data = data; this.clipboardSource = clipboardSource; this.browserSource = browserSource; this.onUi = onUi;
    preferences = new JsonStateStore<WindowsReceiverPreferences>(root, "receiver-intake"); secrets = new(root);
    credentialName = $"{Brand.Name}/{root.NamespaceId}/receiver-browser";
  }
  public async Task RestoreAsync(CancellationToken ct = default)
  {
    var saved = preferences.Load() ?? new();
    if (saved.Port is < 0 or > 65535) throw new IOException("The saved intake port is invalid.");
    current = saved with { Clipboard = false, Browser = false };
    await ConfigureAsync(saved.Clipboard, saved.Browser, ct);
  }
  public async ValueTask ConfigureAsync(bool? clipboard, bool? browser, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      ObjectDisposedException.ThrowIf(disposed, this);
      var next = current with { Clipboard = clipboard ?? current.Clipboard, Browser = browser ?? current.Browser };
      if (next.Browser && http is null)
      {
        var token = await OwnerTokenAsync(ct); http = new(receiver, browserSource, token, current.Port);
        next = next with { Port = http.Port };
      }
      if (!next.Browser && http is not null) { await http.DisposeAsync(); http = null; }
      if (next.Clipboard != current.Clipboard)
        await onUi(() => { if (next.Clipboard) Clipboard.ContentChanged += ClipboardChanged; else Clipboard.ContentChanged -= ClipboardChanged; return Task.CompletedTask; });
      preferences.Save(next); current = next;
    }
    finally { gate.Release(); }
  }
  // Owner-only UI calls this. It is deliberately absent from MCP results.
  public async ValueTask<string> OwnerTokenAsync(CancellationToken ct = default)
  {
    var bytes = await secrets.ReadAsync(credentialName, ct);
    if (bytes is null)
    {
      bytes = Encoding.ASCII.GetBytes(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)));
      await secrets.WriteAsync(credentialName, bytes, ct);
    }
    try { return Encoding.ASCII.GetString(bytes); }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  private async void ClipboardChanged(object? sender, object args)
  {
    if (!current.Clipboard || readingClipboard || disposed) return;
    readingClipboard = true;
    try
    {
      await data.ReadAsync(Clipboard.GetContent(), clipboardSource, "From clipboard");
      Outcome?.Invoke("Clipboard item saved to Receiver.");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Outcome?.Invoke("The clipboard item could not be saved. Check the source and inbox limits."); }
    finally { readingClipboard = false; }
  }
  public async ValueTask DisposeAsync()
  {
    await gate.WaitAsync();
    try
    {
      disposed = true;
      await onUi(() => { Clipboard.ContentChanged -= ClipboardChanged; return Task.CompletedTask; });
      if (http is not null) { await http.DisposeAsync(); http = null; }
    }
    finally { gate.Release(); }
  }
}
