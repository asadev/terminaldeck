using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

/// One row per machine (the Mac's BackendCloudMachineIdentity.swift): what this PC tells the Cloud service about itself
/// so the service keeps ONE row per machine and shows its friendly name, and so its sessions carry one `machine`.
///
/// `machineId` = first 32 hex characters of SHA-256("TD-CLOUD-MACHINE-1\n" + MachineGuid + "\n" + account subject).
/// It survives sign-out, app reinstall and Windows updates (MachineGuid does), differs per PC and per account, and reveals
/// neither input. MachineGuid (`HKLM\SOFTWARE\Microsoft\Cryptography`) is read on demand, only to compute this; it is
/// never stored, logged or sent. A cloned Windows image shares it (accepted, as a restored Mac is on the Mac). The pair the
/// service accepted is remembered only as a hash (device id, machine id, name).
public sealed class CloudMachineFacts(Func<string?> hardwareId, Func<string> computerName, Func<string?> accepted, Action<string> remember, string copy = "")
{
  public sealed record Pair(string MachineId, string DisplayName, string? HostName = null);

  public Func<string?> HardwareId { get; } = hardwareId;
  public Func<string> ComputerName { get; } = computerName;
  public Func<string?> Accepted { get; } = accepted;
  public Action<string> Remember { get; } = remember;
  /// Empty for the installed app. Another copy of the app on the same PC (a test copy) names itself here, so its row
  /// never retires the real app's row.
  public string Copy { get; } = copy;

  /// Null when the hardware id cannot be read (the fields are then simply not sent).
  public Pair? PairFor(string subject, string? hostName = null)
  {
    if (HardwareId() is not { } hardware || subject.Length == 0 || MachineId(hardware, subject, Copy) is not { } id) return null;
    return new(id, DisplayName(ComputerName()), string.IsNullOrEmpty(hostName) ? null : hostName);
  }
  public static string? MachineId(string hardwareId, string subject, string copy = "")
  {
    var hardware = hardwareId.Trim().ToUpperInvariant();
    if (hardware.Length == 0 || subject.Length == 0) return null;
    var label = copy.Length == 0 ? "TD-CLOUD-MACHINE-1" : "TD-CLOUD-MACHINE-1 " + copy;
    return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(label + "\n" + hardware + "\n" + subject)))[..32];
  }
  /// Trimmed, controls removed, at most 64 UTF-16 units (as the service counts); "PC" when nothing is left.
  public static string DisplayName(string raw)
  {
    var plain = new string(raw.Select(c => char.GetUnicodeCategory(c) == UnicodeCategory.Control ? ' ' : c).ToArray()).Trim();
    if (plain.Length > 64) plain = plain[..64];
    if (plain.Length > 0 && char.IsHighSurrogate(plain[^1])) plain = plain[..^1];
    plain = plain.Trim();
    return plain.Length == 0 ? "PC" : plain;
  }
  /// The remembered mark of one accepted pair for one device registration (no input readable from it).
  public static string Mark(string deviceId, Pair pair)
  {
    // A pair sent with its host name has another mark than one sent without: such a PC sends once more.
    var host = pair.HostName is null ? "" : "\nhost " + pair.HostName;
    return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(deviceId + "\n" + pair.MachineId + "\n" + pair.DisplayName + host)));
  }

  /// Which copy of the app this is, for the id's label: empty for the installed app on its standard data folder, so its
  /// id is stable. Another data folder adds a hash of its full path, so two copies on one PC never retire each other's row.
  public static string CopyName(string dataRoot, string standardRoot)
  {
    static string Resolved(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)).ToUpperInvariant();
    var folder = Resolved(dataRoot);
    if (folder == Resolved(standardRoot)) return "";
    return "folder " + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(folder)))[..16];
  }

  /// The real PC: MachineGuid, the computer name, and the accepted mark in one small file of this copy's data folder.
  public static CloudMachineFacts System(string markFile, string copy = "") => new(ReadMachineGuid, () => Environment.MachineName,
    () => { try { return File.Exists(markFile) ? File.ReadAllText(markFile).Trim() : null; } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; } },
    mark =>
    {
      try { Directory.CreateDirectory(Path.GetDirectoryName(markFile)!); var temporary = markFile + ".tmp"; File.WriteAllText(temporary, mark); File.Move(temporary, markFile, true); }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }, copy);

  public static string? ReadMachineGuid()
  {
    if (!OperatingSystem.IsWindows()) return null;
    try
    {
      using var key = Microsoft.Win32.RegistryKey.OpenBaseKey(Microsoft.Win32.RegistryHive.LocalMachine, Microsoft.Win32.RegistryView.Registry64)
        .OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
      return key?.GetValue("MachineGuid") as string;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or global::System.Security.SecurityException) { return null; }
  }
}
