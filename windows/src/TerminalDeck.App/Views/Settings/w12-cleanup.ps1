param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9]{8}T[0-9]{6}Z-settings-w12-[a-z0-9-]+$')][string]$Run,[switch]$OldRoot)
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$source='C:\TD\work\w12-settings-accounts'
$root=if($OldRoot){"C:\TD\settings-proof\$Run"}else{"C:\TD-SettingsProof\$Run"}
$out="C:\TD\out\$Run"
if(!(Test-Path $out)){throw 'The owned proof output is missing'}
if((Test-Path $root) -and ((Get-Item $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The scratch root is a link; cleanup refused'}
$ledger=Join-Path $root 'state\sessions.json'
if((Test-Path $ledger) -and @((Get-Content $ledger -Raw | ConvertFrom-Json).Sessions).Count){throw 'This scratch root has sessions; cleanup refused'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class W12OwnCleanup {
 [DllImport("shell32.dll",EntryPoint="CommandLineToArgvW",CharSet=CharSet.Unicode)] static extern IntPtr Parse(string text,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
 public static string[] Arguments(string text){int count;var p=Parse(text,out count);if(p==IntPtr.Zero)throw new InvalidOperationException("Arguments unavailable");try{var a=new string[count];for(int i=0;i<count;i++)a[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,i*IntPtr.Size));return a;}finally{LocalFree(p);}}
 [DllImport("advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Delete(string target,int kind,int flags);
 [DllImport("advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Read(string target,int kind,int flags,out IntPtr value);
 [DllImport("advapi32.dll",EntryPoint="CredFree")] public static extern void Free(IntPtr value);
 [DllImport("advapi32.dll",EntryPoint="CredEnumerateW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Enumerate(string filter,int flags,out int count,out IntPtr entries);
 [StructLayout(LayoutKind.Sequential)] public struct Head {public uint Flags; public uint Type; public IntPtr Target;}
 public static string[] Targets(string prefix){int count;IntPtr entries;if(!Enumerate(prefix+"*",0,out count,out entries)){if(Marshal.GetLastWin32Error()==1168)return new string[0];throw new InvalidOperationException("Owned credential enumeration failed");}try{var result=new System.Collections.Generic.List<string>();for(int i=0;i<count;i++){var head=Marshal.PtrToStructure<Head>(Marshal.ReadIntPtr(entries,i*IntPtr.Size));var target=Marshal.PtrToStringUni(head.Target);if(target==null||!target.StartsWith(prefix,StringComparison.Ordinal)||head.Type!=1)throw new InvalidOperationException("Credential scope mismatch");result.Add(target);}return result.ToArray();}finally{Free(entries);}}

}
'@
function RootProcesses { @(Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($root)}) }
$stopped=0
foreach($row in (RootProcesses)){
 if($row.Name -cne 'TerminalDeck.Keeper.exe' -or !$row.ExecutablePath.StartsWith($source+'\src\TerminalDeck.App\bin\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected process still uses this root'}
 $supervisorArgs=[W12OwnCleanup]::Arguments($row.CommandLine)
 if($supervisorArgs.Count -ne 3 -or $supervisorArgs[1] -cne '--user-data-dir' -or ![string]::Equals($supervisorArgs[2],$root,[StringComparison]::OrdinalIgnoreCase)){throw 'Supervisor arguments do not match this root'}
 $candidate=Get-Process -Id $row.ProcessId
 try {
  [void]$candidate.Handle
  $again=Get-CimInstance Win32_Process -Filter "ProcessId=$($row.ProcessId)"
  if(!$again -or $again.CreationDate -ne $row.CreationDate -or $again.CommandLine -cne $row.CommandLine -or ![string]::Equals($candidate.Path,$row.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)){throw 'Supervisor identity changed'}
  if(@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($row.ProcessId)").Count){throw 'Supervisor has children; cleanup refused'}
  $candidate.Kill(); if(!$candidate.WaitForExit(15000)){throw 'Owned empty supervisor did not stop'}; $stopped++
 } finally {$candidate.Dispose()}
}
if((RootProcesses).Count){throw 'The root is still in use; credentials were kept'}
$lock=Join-Path $root 'keeper\supervisor.lock'
if(Test-Path $lock){$handle=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$handle.Dispose()}
$brand=[regex]::Match((Get-Content "$source\src\TerminalDeck.Core\Brand.cs" -Raw),'Name\s*=\s*"([^"]+)"').Groups[1].Value
if(!$brand){throw 'Product identity could not be read'}
$hash=[Security.Cryptography.SHA256]::Create()
try {$namespace=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))).Replace('-','').ToLowerInvariant().Substring(0,24)}finally{$hash.Dispose()}
$prefix=$brand+'/'+$namespace+'/'
$removedCredentials=0
foreach($target in [W12OwnCleanup]::Targets($prefix)){
 if(![W12OwnCleanup]::Delete($target,1,0) -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 1168){throw 'Owned credential deletion failed'}
 $removedCredentials++
}
$remaining=[W12OwnCleanup]::Targets($prefix).Length
if($remaining){throw 'Owned credentials remain'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$pointer="C:\TD\share-target\$sid\root.txt"; $removedPointer=$false
if((Test-Path $pointer) -and (Get-Content $pointer -Raw).Trim() -ceq $root){Remove-Item -LiteralPath $pointer; $removedPointer=$true}
if(Test-Path $root){
 if(@(Get-ChildItem $root -Force -Recurse | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Scratch root contains a link; removal refused'}
 Remove-Item -LiteralPath $root -Recurse -Force
}
@{at=(Get-Date).ToUniversalTime().ToString('o');stoppedEmptyOwnedSupervisors=$stopped;remainingCredentials=$remaining;removedCredentials=$removedCredentials;remainingRoot=(Test-Path $root);removedOwnedPointer=$removedPointer;desktopSession=(Get-Process -Id $PID).SessionId} | ConvertTo-Json | Set-Content "$out\owned-cleanup.json"
