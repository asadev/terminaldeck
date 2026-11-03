using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Code;

// GitHub's pure half: the Mac's GitHubRules.swift wording, read from the gh CLI's JSON.
public sealed record GitHubFailure(string Kind, string Message, string? Action = null, string Detail = "");
public sealed record GitHubLabel(string Name, string Color);
public sealed record GitHubRepoRef(string NameWithOwner, string Url, string? DefaultBranch = null, bool IsPrivate = false);
public sealed record GitHubRepoSummary(string NameWithOwner, string Name, string Url, bool IsPrivate, bool Fork, bool Archived, string? Description, string? Language, string? PushedAt, string? DefaultBranch);
public sealed record GitHubPull(int Number, string Title, string Url, string Badge, string? Author, string UpdatedAt, string? Review, IReadOnlyList<GitHubLabel> Labels, bool FromFork, int? Additions, int? Deletions, string Checks);
public sealed record GitHubIssue(int Number, string Title, string Url, string State, string? Author, string UpdatedAt, IReadOnlyList<GitHubLabel> Labels, IReadOnlyList<string> Assignees);
public sealed record GitHubRun(string Name, string Status, string? Conclusion, string Url, string Branch, string CreatedAt);
public sealed record GitHubAuthState(bool Connected, bool GhInstalled, string? Login, string? Name, string? HtmlUrl, string Source, string Host, GitHubFailure? Failure);
public sealed class GitHubException(GitHubFailure failure) : InvalidOperationException(failure.Message)
{
  public GitHubFailure Failure { get; } = failure;
}

public static class GitHubRules
{
  public const string LoginCommand = "gh auth login";
  public const string InstallUrl = "https://cli.github.com/";

  public static string FormatAge(string iso, DateTimeOffset now)
  {
    if (!DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var then)) return "";
    var elapsed = (now - then).TotalSeconds;
    if (elapsed < 60) return "now";
    if (elapsed < 3600) return (int)(elapsed / 60) + "m";
    if (elapsed < 86400) return (int)(elapsed / 3600) + "h";
    if (elapsed < 604800) return (int)(elapsed / 86400) + "d";
    if (elapsed < 31536000) return (int)(elapsed / 604800) + "w";
    return (int)(elapsed / 31536000) + "y";
  }
  public static string? ReviewLabel(string? status) => status switch
  {
    "APPROVED" or "approved" => "Approved", "CHANGES_REQUESTED" or "changes-requested" => "Changes requested", "REVIEW_REQUIRED" or "review-required" => "Review required", _ => null
  };
  public static string FailureTitle(string kind) => kind switch
  {
    "gh-missing" => "GitHub CLI not installed", "not-authenticated" => "Not signed in to GitHub", "auth-expired" => "GitHub sign-in expired",
    "missing-scope" => "Token is missing a permission", "not-a-repo" => "Not a git repository", "no-such-folder" => "Folder is gone",
    "no-remote" => "No git remote", "no-github-remote" => "No GitHub remote", "git-missing" => "git not installed",
    "repo-not-found" => "Repository not found", "no-access" => "No access to this repository", "issues-disabled" => "Issues are off",
    "rate-limited" => "GitHub rate limit reached", "network-down" => "Cannot reach GitHub", "timeout" => "GitHub timed out", _ => "GitHub request failed"
  };
  public static bool IsRetryable(string kind) => kind is "network-down" or "timeout" or "rate-limited" or "error";
  public static string Explanation(GitHubFailure failure) => failure.Action is { Length: > 0 } action ? $"{failure.Message} Run {action} in a terminal, then refresh." : failure.Message;
  public static bool OffersRetry(GitHubFailure failure) => IsRetryable(failure.Kind) || failure.Action is not null;
  public static string SourceWord(string? source) => source switch { "gh-cli" => "GitHub CLI", "environment" => "GH_TOKEN", _ => "not signed in" };
  public static string SourceSentence(string? source, string host) => source switch
  {
    "gh-cli" => $"Reusing the GitHub CLI’s own sign-in on {host} — you were already signed in there.",
    "environment" => $"Using the GH_TOKEN set in the environment this app was launched with, on {host}.",
    _ => $"Not signed in to {host}."
  };
  public static string? CountLabel(int? rows, int limit) => rows is not { } count ? null : count >= limit ? count + "+" : count.ToString(CultureInfo.InvariantCulture);
  public static IReadOnlyList<GitHubRepoSummary> FilterRepos(IReadOnlyList<GitHubRepoSummary> repos, string query)
  {
    var needle = (query ?? "").Trim().ToLowerInvariant();
    return needle.Length == 0 ? repos : repos.Where(r => r.NameWithOwner.Contains(needle, StringComparison.OrdinalIgnoreCase) || (r.Description ?? "").Contains(needle, StringComparison.OrdinalIgnoreCase)).ToArray();
  }
  public static string RepoCountLine(int shown, int limit) => shown >= limit ? $"{limit}+ repositories · showing the {limit} most recently pushed" : shown == 1 ? "1 repository" : $"{shown} repositories";

  // gh's stderr, as one of the Mac's failure kinds.
  public static GitHubFailure Classify(CodeProcessResult result)
  {
    if (result.Missing) return new("gh-missing", "The GitHub CLI (gh) is not installed. Install it from cli.github.com, then refresh.");
    if (result.TimedOut) return new("timeout", "GitHub did not answer in time. Try again.");
    var error = (result.Error + "\n" + result.Output).Trim();
    bool Has(string text) => error.Contains(text, StringComparison.OrdinalIgnoreCase);
    var detail = error.Length > 400 ? error[..400] : error;
    if (Has("HTTP 401") || Has("Bad credentials")) return new("auth-expired", "Your GitHub sign-in was rejected.", LoginCommand, detail);
    if (Has("gh auth login") || Has("not logged") || Has("authentication required") || Has("To get started with GitHub CLI")) return new("not-authenticated", "This computer is not signed in to GitHub.", LoginCommand, detail);
    if (Has("rate limit")) return new("rate-limited", "GitHub's rate limit was reached. Wait a few minutes, then refresh.", null, detail);
    if (Has("none of the git remotes") || Has("no git remotes") || Has("known GitHub host")) return new("no-github-remote", "This repository has no GitHub remote.", null, detail);
    if (Has("not a git repository")) return new("not-a-repo", "This folder is not a git repository.", null, detail);
    if (Has("has disabled issues")) return new("issues-disabled", "Issues are turned off for this repository.", null, detail);
    if (Has("Could not resolve to a Repository") || Has("HTTP 404")) return new("repo-not-found", "GitHub could not find this repository, or your account cannot see it.", null, detail);
    if (Has("HTTP 403") || Has("Resource not accessible")) return new("no-access", "Your GitHub account has no access to this repository.", null, detail);
    if (Has("could not resolve host") || Has("dial tcp") || Has("connection refused") || Has("no such host") || Has("network is unreachable") || Has("error connecting"))
      return new("network-down", "GitHub cannot be reached. Check your connection, then try again.", null, detail);
    var first = error.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
    return new("error", first.Length == 0 ? "The GitHub request failed." : "The GitHub request failed: " + first, null, detail);
  }

  private static string? Text(JsonElement row, string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s ? s : null;
  private static bool Flag(JsonElement row, string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
  private static int? Number(JsonElement row, string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
  private static string? Login(JsonElement row, string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Object ? Text(v, "login") : null;
  private static string? Nested(JsonElement row, string key, string inner) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Object ? Text(v, inner) : null;
  private static IReadOnlyList<GitHubLabel> Labels(JsonElement row) =>
    row.TryGetProperty("labels", out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray().Where(l => Text(l, "name") is not null).Select(l => new GitHubLabel(Text(l, "name")!, Text(l, "color") ?? "888888")).ToArray() : [];

  public static GitHubRepoRef ParseRepoView(string json)
  {
    using var doc = JsonDocument.Parse(json); var row = doc.RootElement;
    return new(Text(row, "nameWithOwner") ?? throw new JsonException("No repository name."), Text(row, "url") ?? "", Nested(row, "defaultBranchRef", "name"), Flag(row, "isPrivate"));
  }
  public static IReadOnlyList<GitHubRepoSummary> ParseRepos(string json)
  {
    using var doc = JsonDocument.Parse(json);
    return doc.RootElement.EnumerateArray().Where(r => Text(r, "nameWithOwner") is not null).Select(r => new GitHubRepoSummary(Text(r, "nameWithOwner")!, Text(r, "name") ?? "", Text(r, "url") ?? "",
      Flag(r, "isPrivate"), Flag(r, "isFork"), Flag(r, "isArchived"), Text(r, "description"), Nested(r, "primaryLanguage", "name"), Text(r, "pushedAt"), Nested(r, "defaultBranchRef", "name"))).ToArray();
  }
  // Every check's result folded to one word: failing beats pending beats passing.
  public static string ChecksSummary(JsonElement row)
  {
    if (!row.TryGetProperty("statusCheckRollup", out var checks) || checks.ValueKind != JsonValueKind.Array || checks.GetArrayLength() == 0) return "";
    var failing = false; var pending = false;
    foreach (var check in checks.EnumerateArray())
    {
      var conclusion = (Text(check, "conclusion") ?? Text(check, "state") ?? "").ToUpperInvariant();
      var status = (Text(check, "status") ?? "").ToUpperInvariant();
      if (conclusion is "FAILURE" or "ERROR" or "TIMED_OUT" or "CANCELLED" or "ACTION_REQUIRED" or "STARTUP_FAILURE") failing = true;
      else if (conclusion is "PENDING" or "EXPECTED" || (status.Length > 0 && status != "COMPLETED")) pending = true;
    }
    return failing ? "failing" : pending ? "pending" : "passing";
  }
  public static IReadOnlyList<GitHubPull> ParsePulls(string json)
  {
    using var doc = JsonDocument.Parse(json);
    return doc.RootElement.EnumerateArray().Where(p => Number(p, "number") is not null).Select(p => new GitHubPull(Number(p, "number")!.Value, Text(p, "title") ?? "", Text(p, "url") ?? "",
      Flag(p, "isDraft") ? "draft" : (Text(p, "state") ?? "OPEN").ToLowerInvariant(), Login(p, "author"), Text(p, "updatedAt") ?? "", Text(p, "reviewDecision"), Labels(p),
      Flag(p, "isCrossRepository"), Number(p, "additions"), Number(p, "deletions"), ChecksSummary(p))).ToArray();
  }
  public static IReadOnlyList<GitHubIssue> ParseIssues(string json)
  {
    using var doc = JsonDocument.Parse(json);
    return doc.RootElement.EnumerateArray().Where(i => Number(i, "number") is not null).Select(i => new GitHubIssue(Number(i, "number")!.Value, Text(i, "title") ?? "", Text(i, "url") ?? "",
      string.Equals(Text(i, "state"), "closed", StringComparison.OrdinalIgnoreCase) ? "closed" : "open", Login(i, "author"), Text(i, "updatedAt") ?? "", Labels(i),
      i.TryGetProperty("assignees", out var a) && a.ValueKind == JsonValueKind.Array ? a.EnumerateArray().Select(x => Text(x, "login")).OfType<string>().ToArray() : [])).ToArray();
  }
  public static IReadOnlyList<GitHubRun> ParseRuns(string json)
  {
    using var doc = JsonDocument.Parse(json);
    return doc.RootElement.EnumerateArray().Select(r => new GitHubRun(Text(r, "workflowName") ?? Text(r, "name") ?? "Workflow", (Text(r, "status") ?? "").ToLowerInvariant(),
      Text(r, "conclusion")?.ToLowerInvariant(), Text(r, "url") ?? "", Text(r, "headBranch") ?? "", Text(r, "createdAt") ?? "")).ToArray();
  }
  public static string RunWord(GitHubRun run) => run.Status != "completed" ? "Running" : run.Conclusion switch
  {
    "success" => "Passed", "failure" => "Failed", "cancelled" => "Cancelled", "skipped" => "Skipped", "timed_out" => "Timed out", { Length: > 0 } other => char.ToUpperInvariant(other[0]) + other[1..], _ => "Finished"
  };
  public static bool SafeWebUrl(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps;
}
