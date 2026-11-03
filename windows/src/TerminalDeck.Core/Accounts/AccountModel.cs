namespace TerminalDeck.Core.Accounts;

public enum AccountAuthentication { Subscription, ApiKey }
public sealed record AccountProfile(string Id, string Provider, string Name, string? Email, AccountAuthentication Authentication,
  bool SignedIn, string HomeId, string? CredentialReference = null, bool ShareHistory = false, string? Color = null, string? Plan = null);
// The account dot colours offered in Coding AIs (named tokens, drawn from the app palette).
public static class AccountColors
{
  public static readonly string[] All = ["blue", "green", "amber", "orange", "red", "purple", "teal", "pink"];
  public static string Name(string? color) => color switch { "blue" => "Blue", "green" => "Green", "amber" => "Amber", "orange" => "Orange", "red" => "Red", "purple" => "Purple", "teal" => "Teal", "pink" => "Pink", _ => "Blue" };
}
public sealed record AccountAlias(string From, string Into);
public sealed record AccountDefault(string Provider, string? Folder, string AccountId);
public sealed record AccountState(int Version, AccountProfile[] Accounts, AccountAlias[] Aliases, AccountDefault[] Defaults);
public sealed record ProviderAccountStatus(bool SignedIn, string? Email, string? Plan = null);
public sealed record ProviderModel(string Id, string Name, int ContextTokens, bool SupportsOneMillion = false, bool IsDefault = false, string[]? Efforts = null);
public sealed record ProviderModelList(ProviderModel[] Models, DateTimeOffset CheckedAt, bool Cached = false);

public interface IAccountProvider
{
  string Provider { get; }
  ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken cancellationToken);
  ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken cancellationToken);
  ValueTask SignOutAsync(AccountProfile account, CancellationToken cancellationToken);
  ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken cancellationToken);
}

public interface IAccountSignInEvents
{
  event Func<string, CancellationToken, ValueTask>? SignInCompleted;
}

public sealed class SignInRequiredException(AccountProfile account) : InvalidOperationException($"Not signed in to {account.Name}. Sign in to continue.")
{
  public string ActionLabel => "Sign in";
  public string AccountId => account.Id;
}

public sealed record ProviderInstallation(bool? Installed, string? Version, DateTimeOffset CheckedAt, string Note);
public interface IAccountInstallation
{
  ValueTask<ProviderInstallation> InstallationAsync(AccountProfile account, CancellationToken cancellationToken);
}
