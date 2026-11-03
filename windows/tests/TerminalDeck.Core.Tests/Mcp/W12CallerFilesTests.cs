using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class W12CallerFilesTests : IDisposable
{
  private readonly string directory = Path.Combine(Path.GetTempPath(), "td-w12-caller-" + Guid.NewGuid().ToString("N"));
  private CallerConnectionFiles Files => new(AppDataRoot.Explicit(directory));
  private string Write(string caller, string name, string token = "synthetic-token")
  {
    var folder = Path.Combine(directory, "mcp", "callers"); Directory.CreateDirectory(folder);
    var path = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".json");
    File.WriteAllText(path, new JsonObject { ["callerId"] = caller, ["name"] = name, ["token"] = token, ["url"] = "http://127.0.0.1/mcp", ["resources"] = new JsonArray("sessions:fixture") }.ToJsonString()); return path;
  }
  [Fact]
  public void RenameChangesOnlyTheNameAndNamesNeverExposeSetupSecrets()
  {
    var first = Write("one", "Work"); var other = Write("two", "Other"); var unchanged = File.ReadAllBytes(other);
    var before = JsonNode.Parse(File.ReadAllText(first))!.AsObject();
    Assert.Equal("Work", Files.Names(["one"])["one"]);
    Assert.Equal("Work AI دبي", Files.Rename("one", " Work AI دبي "));
    var after = JsonNode.Parse(File.ReadAllText(first))!.AsObject(); after["name"] = before["name"]!.DeepClone();
    Assert.True(JsonNode.DeepEquals(before, after)); Assert.Equal(unchanged, File.ReadAllBytes(other));
    Assert.DoesNotContain("synthetic-token", string.Join(" ", Files.Names(["one", "two"]).Values));
  }
  [Fact]
  public void MissingDuplicateAndInvalidNamesCannotOverwriteAConnection()
  {
    var first = Write("one", "Work"); var original = File.ReadAllBytes(first);
    Assert.Throws<McpRefusal>(() => Files.Rename("one", "\n")); Assert.Equal(original, File.ReadAllBytes(first));
    Write("one", "Copy"); Assert.Equal("one", Files.Names(["one"])["one"]);
    Assert.Throws<McpRefusal>(() => Files.Rename("one", "New")); Assert.Equal(original, File.ReadAllBytes(first));
    Assert.Throws<McpRefusal>(() => Files.Rename("missing", "New"));
  }
  [Fact]
  public void UnrelatedBrokenFilesDoNotHideAKnownConnection()
  {
    var path = Write("broken", "Broken"); File.WriteAllText(path, "not-json");
    Write("one", "Work"); Assert.Equal("Work", Files.Names(["one", "missing"])["one"]);
    Assert.Equal("missing", Files.Names(["missing"])["missing"]);
    Files.Rename("one", "Renamed"); Assert.Equal("Renamed", Files.Names(["one"])["one"]);
  }
  [Fact]
  public void InvalidNameMetadataFallsBackToTheStableIdAndCanBeRenamedSafely()
  {
    var path = Write("one", "Work"); var data = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
    data["name"] = 42; File.WriteAllText(path, data.ToJsonString());
    Assert.Equal("one", Files.Names(["one"])["one"]);
    Files.Rename("one", "Recovered"); Assert.Equal("Recovered", Files.Names(["one"])["one"]);
  }
  [Fact]
  public void DuplicateJsonPropertiesCannotHideOrOverwriteAnUnrelatedKey()
  {
    var broken = Write("broken", "Broken"); File.WriteAllText(broken, "{\"callerId\":\"broken\",\"callerId\":\"other\"}");
    var known = Write("one", "Work"); var original = File.ReadAllBytes(known);
    Assert.Equal("Work", Files.Names(["one"])["one"]);
    Assert.Throws<McpRefusal>(() => Files.Rename("broken", "New")); Assert.Equal(original, File.ReadAllBytes(known));
  }
  public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
}
