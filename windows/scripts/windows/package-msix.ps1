<#
  Builds the signed Windows installer (TerminalDeck-<version>-x64.msix) from this source, the same way the
  private release PC did (tools/win/release-real.ps1 on saba-pc, up to 0.21.2.0), on any Windows machine with the
  .NET SDK from global.json, Visual Studio (C++ x64 tools + Windows App SDK workload) and the Windows SDK.
  GitHub's windows-2025 runners have all of these; .github/workflows/windows-release.yml calls this script.

    pwsh -File windows\scripts\windows\package-msix.ps1 -Version 0.21.5.0 -Out <folder> `
         -PfxPath <TerminalDeck Stable .pfx> -LinkNative <folder made by src\TerminalDeck.Link.Native\build.ps1>
    The .pfx password comes from the environment variable WINDOWS_SIGNING_PFX_PASSWORD, never the command line.

  It refuses a signing certificate that is not the one installed PCs already trust (CN=Terminal Deck Stable,
  SHA-1 thumbprint 2539F637233ED387682AD54E1A5C3D5B3633A96E, valid to 2041, the TerminalDeck-Stable.cer of every
  release since 0.20): a different certificate would make every installed copy refuse the update. Without -PfxPath it stops after the unsigned package (for a dry build).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')][string] $Version,
  [Parameter(Mandatory = $true)][string] $Out,
  [string] $PfxPath,
  [string] $LinkNative
)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$layout = Join-Path $Out 'layout'
if (Test-Path $layout) { throw "$layout already exists; use a fresh -Out folder" }
$log = Join-Path $Out 'package-msix.log'
function Sdk([string] $name) {
  $found = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$name" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if (!$found) { throw "Windows SDK tool $name not found" }
  $found.FullName
}
function Run([string] $what, [string[]] $arguments) {
  & dotnet @arguments *>> $log
  if ($LASTEXITCODE) { Get-Content $log -Tail 40 | Write-Host; throw "$what failed ($LASTEXITCODE)" }
}
$nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:Platform=x64', '-nologo')
Push-Location $root
try {
  # 1. The app, its keeper and the two helpers.
  $appArgs = @('publish', 'src/TerminalDeck.App/TerminalDeck.App.csproj') + $common + @('-p:WindowsAppSDKSelfContained=true', '-o', $layout)
  if ($LinkNative) { $appArgs += "-p:TdLinkNative=$((Resolve-Path $LinkNative).Path)" } else { Write-Warning 'No -LinkNative: phones cannot use the direct link with this build.' }
  Run 'App publish' $appArgs
  $built = Join-Path $root 'src\TerminalDeck.App\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64'
  $keeperBundle = (Get-Content (Join-Path $built 'keeper-location.txt') -Raw).Trim()
  if ($keeperBundle -notmatch '^[0-9]{17}$') { throw 'Published keeper bundle marker is missing' }
  $keeperLayout = Join-Path $layout "keeper\$keeperBundle"
  Run 'Keeper publish' (@('publish', 'src/TerminalDeck.Keeper/TerminalDeck.Keeper.csproj') + $common + @('-o', $keeperLayout))
  Copy-Item (Join-Path $built 'keeper-location.txt') (Join-Path $layout 'keeper-location.txt') -Force
  foreach ($helper in @(@('src/TerminalDeck.ToolBridge/TerminalDeck.ToolBridge.csproj', 'tools-bridge'), @('tests/TerminalDeck.Servers.Askpass/TerminalDeck.Servers.Askpass.csproj', 'askpass'))) {
    Run "$($helper[1]) publish" (@('publish', $helper[0]) + $common + @('-o', (Join-Path $keeperLayout $helper[1])))
  }
  foreach ($file in @('TerminalDeck.Keeper.exe', 'TerminalDeck.Keeper.dll', 'TerminalDeck.Core.dll', 'TerminalDeck.Platform.Windows.dll', 'hostfxr.dll')) {
    if (!(Test-Path (Join-Path $keeperLayout $file))) { throw "Published keeper is incomplete: $file" }
  }
  foreach ($file in @('dompurify\dist\purify.min.js', 'katex\dist\katex.min.js', 'mermaid\dist\mermaid.min.js')) {
    if (!(Test-Path (Join-Path $layout "Assets\chat\$file"))) { throw "Chat library missing from the layout: $file" }
  }

  # 2. An unpackaged WinUI publish omits the app's PRI and compiled XAML: copy them in.
  $pri = Join-Path $built 'TerminalDeck.App.pri'
  if (!(Test-Path $pri) -or !(Test-Path "$layout\TerminalDeck.App.exe")) { throw 'WinUI build resources or publish layout missing' }
  Copy-Item $pri "$layout\TerminalDeck.App.pri" -Force
  Copy-Item $pri "$layout\resources.pri" -Force
  foreach ($file in Get-ChildItem $built -Filter '*.xbf' -Recurse) {
    $target = Join-Path $layout $file.FullName.Substring($built.Length + 1)
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $file.FullName $target -Force
  }

  # 3. Tile logos from the app icon.
  Add-Type -AssemblyName System.Drawing
  $brandImage = [System.Drawing.Image]::FromFile("$layout\Assets\icons\app.png")
  try {
    foreach ($size in @(50, 150)) {
      $bitmap = New-Object System.Drawing.Bitmap($size, $size)
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($brandImage, 0, 0, $size, $size)
        $bitmap.Save("$layout\logo$size.png", [System.Drawing.Imaging.ImageFormat]::Png)
      } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
  } finally { $brandImage.Dispose() }

  # 4. The package manifest: the identity installed PCs know (name, publisher), this version.
  @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap desktop6">
 <Identity Name="TerminalDeck" Publisher="CN=Terminal Deck Stable" Version="$Version" ProcessorArchitecture="x64" />
 <Properties><DisplayName>Terminal Deck</DisplayName><PublisherDisplayName>Terminal Deck</PublisherDisplayName><Logo>logo50.png</Logo><desktop6:FileSystemWriteVirtualization>disabled</desktop6:FileSystemWriteVirtualization></Properties>
 <Resources><Resource Language="en-us" /></Resources>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" /></Dependencies>
 <Applications><Application Id="App" Executable="TerminalDeck.App.exe" EntryPoint="Windows.FullTrustApplication"><uap:VisualElements DisplayName="Terminal Deck" Description="Terminal Deck" BackgroundColor="transparent" Square150x150Logo="logo150.png" Square44x44Logo="logo50.png" /></Application></Applications>
 <Capabilities><rescap:Capability Name="runFullTrust" /><rescap:Capability Name="unvirtualizedResources" /></Capabilities>
</Package>
"@ | Set-Content "$layout\AppxManifest.xml" -Encoding UTF8
  # Share target, and the native activation registrations of the exact Windows App SDK packages used.
  [xml] $manifest = Get-Content "$layout\AppxManifest.xml"
  $app = $manifest.Package.Applications.Application
  $shareExtensions = $manifest.CreateElement('Extensions', $manifest.DocumentElement.NamespaceURI)
  [xml] $share = Get-Content (Join-Path $root 'src/TerminalDeck.Platform.Windows/Receiver/ShareTarget.appxmanifest.xml')
  $shareExtensions.AppendChild($manifest.ImportNode($share.DocumentElement, $true)) | Out-Null
  $app.AppendChild($shareExtensions) | Out-Null
  $extensions = $manifest.CreateElement('Extensions', $manifest.DocumentElement.NamespaceURI)
  $manifest.DocumentElement.AppendChild($extensions) | Out-Null
  $assets = Get-Content (Join-Path $root 'src\TerminalDeck.App\obj\project.assets.json') -Raw | ConvertFrom-Json
  $fragments = 0
  foreach ($library in $assets.libraries.PSObject.Properties.Name) {
    $fragment = Join-Path $nuget ($library.ToLowerInvariant().Replace('/', '\') + '\runtimes-framework\package.appxfragment')
    if (Test-Path $fragment) {
      $fragments++
      [xml] $sdk = Get-Content $fragment
      foreach ($extension in $sdk.Fragment.Extensions.ChildNodes) {
        if ($extension.NodeType -eq [Xml.XmlNodeType]::Element) { $extensions.AppendChild($manifest.ImportNode($extension, $true)) | Out-Null }
      }
    }
  }
  if ($fragments -eq 0) { throw "No Windows App SDK package.appxfragment found under $nuget" }
  $manifest.Save("$layout\AppxManifest.xml")
  Set-Content "$layout\terminaldeck-stable-channel" 'stable-v1'
  Set-Content "$keeperLayout\terminaldeck-stable-channel" 'stable-v1'

  # 5. Pack, then sign with the Terminal Deck Stable certificate (only that one).
  $name = "TerminalDeck-$Version-x64.msix"
  $package = Join-Path $Out $name
  & (Sdk 'makeappx.exe') pack /d $layout /p $package /o *>> $log
  if ($LASTEXITCODE) { Get-Content $log -Tail 40 | Write-Host; throw 'MSIX packing failed' }
  if (!$PfxPath) { Write-Host "Unsigned package (no -PfxPath): $package"; return }
  $password = $env:WINDOWS_SIGNING_PFX_PASSWORD
  if (!$password) { throw 'WINDOWS_SIGNING_PFX_PASSWORD is not set' }
  $trustedThumbprint = '2539F637233ED387682AD54E1A5C3D5B3633A96E'
  $signer = [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
  if ($signer.Thumbprint -ne $trustedThumbprint -or $signer.Subject -ne 'CN=Terminal Deck Stable' -or !$signer.HasPrivateKey) { throw "The signing certificate ($($signer.Subject), $($signer.Thumbprint)) is not the Terminal Deck Stable certificate installed PCs trust ($trustedThumbprint)." }
  $publicCer = Join-Path $Out 'TerminalDeck-Stable.cer'
  [IO.File]::WriteAllBytes($publicCer, $signer.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
  if ($signer.NotAfter -lt (Get-Date).AddMonths(6)) { throw 'The Terminal Deck Stable certificate expires within six months' }
  & (Sdk 'signtool.exe') sign /fd SHA256 /f $PfxPath /p $password $package *>> $log
  if ($LASTEXITCODE) { throw 'Signing failed' }
  # signtool verify needs the self-signed certificate trusted on this machine (a throwaway runner: harmless).
  Import-Certificate -FilePath $publicCer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
  Import-Certificate -FilePath $publicCer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  & (Sdk 'signtool.exe') verify /pa $package *>> $log
  if ($LASTEXITCODE) { throw 'Signature verification failed' }

  # 6. The package says what the update file will promise.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($package)
  try { $reader = [IO.StreamReader]::new($zip.GetEntry('AppxManifest.xml').Open()); [xml] $inside = $reader.ReadToEnd(); $reader.Dispose() } finally { $zip.Dispose() }
  $id = $inside.Package.Identity
  if ($id.Name -ne 'TerminalDeck' -or $id.Publisher -ne 'CN=Terminal Deck Stable' -or $id.Version -ne $Version -or $id.ProcessorArchitecture -ne 'x64') { throw 'The packed identity is not TerminalDeck / CN=Terminal Deck Stable / x64 / this version' }
  Write-Host "Signed: $package ($((Get-Item $package).Length) bytes, SHA-256 $((Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()))"
}
finally { Pop-Location }
