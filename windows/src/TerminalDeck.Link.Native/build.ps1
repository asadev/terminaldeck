# Builds the Windows link engine: tdlink.dll (this folder's tdlink.cpp, MSVC x64) against webrtc-sdk's libwebrtc.dll,
# pinned by release and SHA-256, and puts tdlink.dll + libwebrtc.dll + the licence texts in -Out.
#   powershell -File build.ps1 -Out <folder>
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$release = 'libwebrtc.m150.7871.07'
$sha256 = '0CF141CD803AF8F860080D94861D2D591AB9081A28F5CDEAD1B7C775AD5D3BF8'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = Join-Path $Out 'obj'
New-Item -ItemType Directory -Force $work | Out-Null

$zip = Join-Path $work "$release-win-x64.zip"
if (!(Test-Path $zip) -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $sha256) {
  Invoke-WebRequest "https://github.com/webrtc-sdk/libwebrtc/releases/download/$release/libwebrtc-win-x64-release.zip" -OutFile $zip -UseBasicParsing
}
$got = (Get-FileHash $zip -Algorithm SHA256).Hash
if ($got -ne $sha256) { Remove-Item $zip -Force; throw "libwebrtc download has SHA-256 $got, expected $sha256" }
$unpacked = Join-Path $work $release
if (!(Test-Path (Join-Path $unpacked 'libwebrtc-x64-release\lib\libwebrtc.dll'))) {
  if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
  Expand-Archive $zip -DestinationPath $unpacked
}
$sdk = Join-Path $unpacked 'libwebrtc-x64-release'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'No MSVC x64 tools (Visual Studio Build Tools with the C++ x64 compiler) on this PC.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $here 'tdlink.cpp'
# Static CRT (/MT) like libwebrtc.dll itself: no Visual C++ runtime to install. The defines match the vtables
# libwebrtc.dll was built with (its BUILD.gn external_config).
$cl = "cl /nologo /std:c++17 /O2 /EHsc /MT /LD /W3 /DLIB_WEBRTC_API_DLL /DRTC_DESKTOP_DEVICE /DWIN32 /D_WINDOWS " +
  "/I`"$sdk\include`" `"$source`" /Fo`"$work\\`" /Fe`"$Out\tdlink.dll`" /link /DLL `"$sdk\lib\libwebrtc.dll.lib`""
cmd /c "call `"$vcvars`" >nul && $cl"
if ($LASTEXITCODE -ne 0) { throw "tdlink.dll did not compile ($LASTEXITCODE)" }
Copy-Item (Join-Path $sdk 'lib\libwebrtc.dll') $Out -Force
$licenses = Join-Path $Out 'licenses\webrtc'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item (Join-Path $here 'licenses\*') $licenses -Force
Get-ChildItem $Out -Filter 'tdlink.*' | Where-Object { $_.Extension -in '.exp', '.lib' } | Remove-Item -Force
"tdlink.dll + libwebrtc.dll ($release) -> $Out"
