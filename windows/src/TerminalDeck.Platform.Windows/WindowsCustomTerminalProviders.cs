using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public static class WindowsCustomTerminalProviders
{
  public static CustomTerminalProviders Open(AppDataRoot root) => new(new ProtectedStore(root));
  // Environment values live in root-scoped Credential Manager slots. The whole
  // envelope is DPAPI protected too, since literal CLI arguments can be private.
  private sealed class ProtectedStore : IStateStore<CustomTerminalProviderState>
  {
    private readonly JsonStateStore<byte[]> store;
    private readonly CurrentUserDpapi protector;
    private readonly WindowsCredentialStore secrets;
    private readonly object gate = new();
    public ProtectedStore(AppDataRoot root) { store = new(root, "custom-terminal-providers-protected"); protector = new(root); secrets = new(root); }
    private CustomTerminalProviderState? Envelope()
    {
      if (store.Load() is not { } encrypted) return null;
      var bytes = protector.Unprotect(encrypted);
      try { return JsonSerializer.Deserialize<CustomTerminalProviderState>(bytes) ?? throw new IOException("The custom CLI definitions could not be read."); }
      finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private static string Slot(string reference) => Regex.IsMatch(reference, "^custom-cli-env-[a-f0-9]{32}$") ? reference : throw new IOException("This custom CLI has an invalid protected environment reference.");
    public CustomTerminalProviderState? Load()
    {
      lock (gate)
      {
        if (Envelope() is not { } state) return null;
        return new(state.Providers.Select(p => p with { Environment = p.Environment.ToDictionary(v => v.Key, v =>
        {
          var bytes = secrets.ReadAsync(Slot(v.Value)).AsTask().GetAwaiter().GetResult() ?? throw new IOException("A custom CLI environment value is no longer available. Edit that definition again.");
          try { return Encoding.UTF8.GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
        }, StringComparer.OrdinalIgnoreCase) }).ToArray());
      }
    }
    public void Save(CustomTerminalProviderState state)
    {
      lock (gate)
      {
        var previous = Envelope(); var made = new List<string>();
        try
        {
          var envelope = new CustomTerminalProviderState(state.Providers.Select(p => p with { Environment = p.Environment.ToDictionary(v => v.Key, v =>
          {
            var slot = "custom-cli-env-" + Guid.NewGuid().ToString("N"); var bytes = Encoding.UTF8.GetBytes(v.Value);
            try { secrets.WriteAsync(slot, bytes).AsTask().GetAwaiter().GetResult(); made.Add(slot); return slot; }
            finally { CryptographicOperations.ZeroMemory(bytes); }
          }, StringComparer.OrdinalIgnoreCase) }).ToArray());
          var clear = JsonSerializer.SerializeToUtf8Bytes(envelope);
          try { store.Save(protector.Protect(clear)); } finally { CryptographicOperations.ZeroMemory(clear); }
        }
        catch
        {
          foreach (var slot in made) try { secrets.DeleteAsync(slot).AsTask().GetAwaiter().GetResult(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
          throw;
        }
        foreach (var slot in previous?.Providers.SelectMany(p => p.Environment.Values) ?? [])
          try { secrets.DeleteAsync(Slot(slot)).AsTask().GetAwaiter().GetResult(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
      }
    }
  }
}
