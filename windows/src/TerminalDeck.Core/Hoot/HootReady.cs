using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Hoot;

// Hoot is ready the moment the app opens (Asad, 30 Oct: "Hoot should always be
// already set up"). Like the Mac's HootReadyDefaults: its own folder under the
// app's data root, the first signed-in AI in Claude, Codex, Gemini order, the
// AI's own default model, the app's default effort and permission. Saved
// choices are never overwritten; only an unconfigured Hoot is filled in.
public sealed class HootReady(string home, Func<string, AiPermissionMode>? permission = null, Func<string, (string Model, string? Effort)>? launch = null)
{
  public static readonly string[] ProviderOrder = ["claude", "codex", "gemini"];
  public const string SignInLine = "Sign in to Claude, Codex or Gemini to start Hoot.";
  public string Home { get; } = home;
  public static HootReady For(AppDataRoot root, Func<string, AiPermissionMode>? permission = null) =>
    new(Path.Combine(root.DirectoryPath, "hoot"), permission, provider => TerminalDeck.Core.Settings.LaunchDefaults.For(provider, root));

  // The Mac's folder contents: the home folder and its memory index. Existing
  // files are kept byte for byte.
  public string EnsureFolder()
  {
    var memory = Path.Combine(Home, "memory");
    Directory.CreateDirectory(memory);
    var index = Path.Combine(memory, "MEMORY.md");
    if (!File.Exists(index))
    {
      try
      {
        using var file = new FileStream(index, FileMode.CreateNew, FileAccess.Write);
        using var writer = new StreamWriter(file);
        writer.Write("# Memory index\n\nOne file per fact, in this directory. This file lists them, newest first.\n\nNothing has been remembered yet.\n");
      }
      catch (IOException) when (File.Exists(index)) { }
    }
    return Home;
  }

  // The account Hoot connects to: per AI in order, that AI's chosen default when
  // it is signed in, else its first signed-in account.
  public static AccountProfile? PickAccount(AccountService accounts)
  {
    foreach (var provider in ProviderOrder)
    {
      AccountProfile? preferred = null;
      try { preferred = accounts.Preferred(provider); } catch (ArgumentException) { } // a stale default must not block Hoot
      if (preferred is { SignedIn: true }) return preferred;
      if (accounts.List(provider).FirstOrDefault(a => a.SignedIn) is { } signedIn) return signedIn;
    }
    return null;
  }

  // Out of the box: Auto where the AI has it (Claude), else Bypass, unless the
  // person's own app default (General settings) names one this AI supports.
  public AiPermissionMode PermissionFor(string provider)
  {
    var supported = ChatPermissionModes.Supported(provider);
    if (permission?.Invoke(provider) is { } chosen && supported.Contains(chosen)) return chosen;
    return supported.Contains(AiPermissionMode.Auto) ? AiPermissionMode.Auto : supported.Contains(AiPermissionMode.Bypass) ? AiPermissionMode.Bypass : AiPermissionMode.Ask;
  }

  // The Mac's default effort is Extra where the AI offers it; otherwise High,
  // and Gemini has no effort choice at all. The model stays the AI's own default.
  public static string EffortFor(string provider, ProviderModel? model)
  {
    var offered = ModelEfforts.For(provider, model);
    return offered.Contains("xhigh") ? "xhigh" : offered.Contains("high") ? "high" : "";
  }

  public HootSettings? Settings(AccountService accounts)
  {
    if (PickAccount(accounts) is not { } account) return null;
    // The app-wide "New sessions start with" choice (Settings > Coding AIs) wins,
    // so Hoot starts on the same model and level as every other new chat.
    var cached = accounts.CachedModels(account.Id)?.Models;
    if (launch?.Invoke(account.Provider) is { Model.Length: > 0 } wide)
    {
      var chosen = cached?.FirstOrDefault(m => m.Id == wide.Model) ?? ModelCatalog.For(account.Provider).FirstOrDefault(m => m.Id == wide.Model);
      var effort = wide.Effort is { Length: > 0 } level && (chosen is null || ModelEfforts.For(account.Provider, chosen).Contains(level)) ? level : EffortFor(account.Provider, chosen);
      return new(account.Provider, account.Id, EnsureFolder(), new(wide.Model, effort), PermissionMode: PermissionFor(account.Provider));
    }
    var model = cached?.FirstOrDefault(m => m.IsDefault);
    return new(account.Provider, account.Id, EnsureFolder(), new("", EffortFor(account.Provider, model)), PermissionMode: PermissionFor(account.Provider));
  }
}
