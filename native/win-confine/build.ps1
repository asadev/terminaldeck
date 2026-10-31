<#
  Builds tdconfine.exe with MSVC, on a developer machine and on `windows-latest`
  in CI, from the same script.

  ## Why a script rather than a line in the workflow

  Because a launcher that only builds on somebody's laptop will not ship, and
  the way that happens is that the workflow grows a compile command nobody can
  run locally to check. This is the one command, and `release.yml` calls it.

  ## Why locating MSVC is four steps rather than `cl tdconfine.c`

  `cl.exe` is not on the PATH of a fresh `windows-latest` runner, or of any
  machine where Visual Studio is installed but a Developer Command Prompt has
  not been opened. It lives inside a versioned directory and needs a dozen
  environment variables set before it can find its own headers. `vswhere.exe`
  is the supported way to ask where Visual Studio is (it ships at a fixed path
  with the installer, on every machine that has any edition) and `VsDevCmd.bat`
  is the supported way to get the variables. Running that batch file and
  importing what it exports is the whole of the setup.

  ## This file is deliberately pure ASCII

  Windows PowerShell 5.1, which is what a `windows-latest` runner uses for a
  `shell: powershell` step, reads a .ps1 as the machine's ANSI code page unless
  the file carries a UTF-8 byte-order mark. An em dash inside a double-quoted
  string therefore terminated the string early and produced five cascading
  parse errors that named the wrong lines - measured, on the first run of this
  script. A build script that depends on its own encoding is a build script
  that breaks on somebody else's machine, so there is nothing here above U+007F.

  Run against a real Visual Studio Build Tools 2022 install on Windows 11 26200
  before it was committed. The warnings it turns into errors are not
  decorative: this is security-critical code, and /W4 /WX is the cheapest
  reviewer it will ever have.

  ## Parameters

  -OutDir  where to put tdconfine.exe. Defaults to this directory.
#>

[CmdletBinding()]
param(
  [string] $OutDir
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY inside a param() default block in Windows PowerShell
# 5.1 - measured, not read: a default of `[string] $OutDir = $PSScriptRoot`
# produced "Cannot bind argument to parameter 'Path' because it is an empty
# string" from a Join-Path forty lines further down, which names neither the
# parameter nor the reason. It is populated by the time the body runs, so the
# default is applied here instead.
if (-not $OutDir) { $OutDir = $PSScriptRoot }

$source = Join-Path $PSScriptRoot 'tdconfine.c'
if (-not (Test-Path $source)) { throw "tdconfine.c is not next to this script ($source)" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# vswhere ships with the Visual Studio Installer and lives at this exact path on
# every machine that has any edition, including the hosted runners. Its absence
# means Visual Studio is absent, and saying so is more useful than a compiler
# that cannot be found four steps later.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
  throw "vswhere.exe was not found at $vswhere. Visual Studio or Build Tools with the C++ workload is required."
}

# '-products *' matters: without it vswhere ignores Build Tools installs, which
# is what CI and a headless machine will have.
$install = & $vswhere -latest -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath
if (-not $install) {
  throw 'No Visual Studio install with the MSVC x64 C++ tools was found. Install the "Desktop development with C++" workload.'
}

$devcmd = Join-Path $install 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $devcmd)) { throw "VsDevCmd.bat was not found under $install" }

# Run the batch file and import what it set. '-no_logo' keeps its banner out of
# the variable list; the marker line separates the batch file's own output from
# the environment dump, because VsDevCmd prints diagnostics on some installs and
# parsing those as variables would set nonsense.
$dump = & "$env:ComSpec" /s /c "`"$devcmd`" -arch=amd64 -host_arch=amd64 -no_logo && echo ___MARKER___ && set"
$past = $false
foreach ($line in $dump) {
  # .Trim() is load-bearing: `echo ___MARKER___ && set` makes cmd echo the
  # space in front of the `&&` too, so the marker arrives as "___MARKER___ "
  # and an equality test against it silently never matches - which imports no
  # variables at all and reports the failure forty lines later as "cl.exe is
  # still not on the PATH". Measured on the second run of this script.
  if ($line.Trim() -eq '___MARKER___') { $past = $true; continue }
  if (-not $past) { continue }
  $split = $line.IndexOf('=')
  if ($split -lt 1) { continue }
  Set-Item -Path ('Env:' + $line.Substring(0, $split)) -Value $line.Substring($split + 1)
}

$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl) { throw 'cl.exe is still not on the PATH after VsDevCmd.bat. The C++ workload is probably not installed.' }

$exe = Join-Path $OutDir 'tdconfine.exe'
$obj = Join-Path $OutDir 'tdconfine.obj'

# /W4 /WX          this file is small enough that every warning is worth an error.
# /GS /guard:cf    stack cookies and Control Flow Guard. It is a security tool, so
#                  it gets the security flags.
# /DYNAMICBASE /HIGHENTROPYVA /NXCOMPAT  ASLR and DEP, stated rather than assumed.
# advapi32         the ACL and SID calls. user32: the window station and desktop.
#                  userenv is NOT here: the AppContainer entry points are resolved
#                  with GetProcAddress at run time, which is what keeps the import
#                  list identical under MSVC and under mingw-w64.
& $cl.Source /nologo /W4 /WX /O2 /GS /guard:cf /std:c11 /DUNICODE /D_UNICODE `
  /Fe:$exe /Fo:$obj $source `
  /link /SUBSYSTEM:CONSOLE /DYNAMICBASE /HIGHENTROPYVA /NXCOMPAT `
  advapi32.lib user32.lib kernel32.lib
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed with exit code $LASTEXITCODE" }

Remove-Item $obj -ErrorAction SilentlyContinue

# A build that produced nothing is a build that failed quietly, and this file is
# the one thing between a confined session and an unconfined one.
if (-not (Test-Path $exe)) { throw "cl.exe reported success but $exe is not there" }
Write-Output "built $exe ($((Get-Item $exe).Length) bytes)"
