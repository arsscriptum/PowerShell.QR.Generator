<#
.SYNOPSIS
    Generates a QR code image from text or raw bytes and displays it.

.DESCRIPTION
    Invoke-GenerateQR uses the QRCoder library (pulled via NuGet on first run,
    then cached) to produce a PNG QR code from either a string or a byte array.
    The resulting image is saved to a temp file and opened with the default
    system viewer.

.PARAMETER Text
    A string to encode. Accepts any Unicode text including multi-line vCards,
    mailto URIs, URLs, etc.

.PARAMETER Bytes
    A raw byte array to encode. When supplied, Text is ignored.

.PARAMETER OutputPath
    Optional. Full path for the output PNG. Defaults to a temp file.

.PARAMETER PixelsPerModule
    Size in pixels of each QR module (dot). Default: 10.

.PARAMETER ErrorCorrection
    QR error correction level: L, M, Q, H. Default: M.

.PARAMETER NoDisplay
    Suppress launching the image viewer. The output path is still written to
    the pipeline.

.PARAMETER TestLimits
    Suppress arguments length validation so that we can test the size limits
    See Test-QRMaxSize.ps1 script.

.EXAMPLE
    $TestStr = @"
Guillaume Plante
mailto:planteg@proton.me
"@
    Invoke-GenerateQR -Text $TestStr

.EXAMPLE
    $url      = "https://www.test.com"
    $encoding = [System.Text.Encoding]::UTF8
    $ba       = New-Object byte[] ($encoding.GetByteCount($url))
    $encoding.GetBytes($url, 0, $url.Length, $ba, 0)
    Invoke-GenerateQR -Bytes $ba
#>

#Requires -Version 7.0

function Invoke-GenerateQR {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text', Position = 0)]
        [string] $Text,

        [Parameter(Mandatory, ParameterSetName = 'Bytes', Position = 0)]
        [byte[]] $Bytes,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateRange(1, 50)]
        [int] $PixelsPerModule = 10,

        [Parameter()]
        [ValidateSet('L', 'M', 'Q', 'H')]
        [string] $ErrorCorrection = 'M',

        [Parameter()]
        [switch] $NoDisplay,

        [Parameter()]
        [switch] $TestLimits
    )
    $AllowOverflow = $TestLimits -eq $True
    # Max binary bytes per QR spec v40 for each ECC level
    $qrMaxBytes = @{ L = 2953; M = 2331; Q = 1663; H = 1273 }
    $limit      = $qrMaxBytes[$ErrorCorrection]
    if($AllowOverflow -eq $False){
        if ($PSCmdlet.ParameterSetName -eq 'Text') {
            $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Text)
            if ($byteCount -gt $limit) {
                
                [System.Management.Automation.ErrorRecord]$ErrorEntry = [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Text encodes to $byteCount UTF-8 bytes. Max for ECC '$ErrorCorrection' is $limit bytes."),
                        'QRTextTooLong',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $Text
                    )
          
                 throw $ErrorEntry
                              
                
            }
        } else {
            if ($Bytes.Length -gt $limit) {
                
                    [System.Management.Automation.ErrorRecord]$ErrorEntry = [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Byte array is $($Bytes.Length) bytes. Max for ECC '$ErrorCorrection' is $limit bytes."),
                        'QRByteArrayTooLong',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $Bytes
                    )
        
                    throw $ErrorEntry
            }
        }
   }

    # ── 1. Resolve / create output path ──────────────────────────────────────
    if (-not $OutputPath) {
        $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "qr_$(Get-Random).png"
    }

    # ── 2. Ensure QRCoder is available ────────────────────────────────────────
    $cacheDir   = Join-Path $env:LOCALAPPDATA 'PSQRCoder'
    $markerFile = Join-Path $cacheDir 'qrcoder.loaded'

    # Locate DLL (may already be cached from a previous run)
    $dll = Get-ChildItem -Path $cacheDir -Filter 'QRCoder.dll' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName

    if (-not $dll) {
        Write-Host '[QRCoder] First run — downloading via NuGet...' -ForegroundColor Cyan

        # Verify dotnet CLI is present
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            throw 'dotnet CLI not found. Install the .NET SDK (https://dot.net) or place QRCoder.dll manually in: {0}' -f $cacheDir
        }

        $null = New-Item -ItemType Directory -Path $cacheDir -Force

        # Create a throwaway project to restore QRCoder
        $tmpProj = Join-Path ([System.IO.Path]::GetTempPath()) "qrcoder_restore_$(Get-Random)"
        $null    = New-Item -ItemType Directory -Path $tmpProj -Force

        $csprojContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Library</OutputType>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="QRCoder" Version="1.6.0" />
  </ItemGroup>
</Project>
'@
        Set-Content -Path (Join-Path $tmpProj 'restore.csproj') -Value $csprojContent -Encoding UTF8

        # Restore only (no build needed)
        $restoreArgs = @('restore', (Join-Path $tmpProj 'restore.csproj'),
                         '--packages', $cacheDir, '--verbosity', 'quiet')
        $result = & dotnet @restoreArgs
        if ($LASTEXITCODE -ne 0) {
            throw "NuGet restore failed (exit $LASTEXITCODE). Check internet access."
        }

        Remove-Item -Recurse -Force $tmpProj -ErrorAction SilentlyContinue

        # Locate the restored DLL (net standard 2.0 is the widest-compat target QRCoder ships)
        $dll = Get-ChildItem -Path $cacheDir -Filter 'QRCoder.dll' -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match 'netstandard2\.0|net4' } |
               Select-Object -First 1 -ExpandProperty FullName

        # Fallback: any DLL if the above filter matched nothing
        if (-not $dll) {
            $dll = Get-ChildItem -Path $cacheDir -Filter 'QRCoder.dll' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
        }

        if (-not $dll) {
            throw "QRCoder.dll not found after restore. Check: $cacheDir"
        }

        Write-Host "[QRCoder] Cached to: $dll" -ForegroundColor Green
    }

    # Load the assembly (safe to call multiple times — .NET deduplicates)
    try {
        Add-Type -Path $dll -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -notmatch 'already loaded') { throw }
    }

    # ── 3. Build QR payload ───────────────────────────────────────────────────
    $ecLevel = [QRCoder.QRCodeGenerator+ECCLevel]::$ErrorCorrection

    $generator = [QRCoder.QRCodeGenerator]::new()

    $qrData = if ($PSCmdlet.ParameterSetName -eq 'Bytes') {
        # QRCoder accepts raw bytes via the overload that takes byte[] directly
        $generator.CreateQrCode($Bytes, $ecLevel)
    } else {
        $generator.CreateQrCode($Text, $ecLevel)
    }

    # ── 4. Render to PNG using PngByteQRCode (no System.Drawing dependency) ──
    $pngRenderer = [QRCoder.PngByteQRCode]::new($qrData)
    $pngBytes    = $pngRenderer.GetGraphic($PixelsPerModule)

    [System.IO.File]::WriteAllBytes($OutputPath, $pngBytes)

    Write-Verbose "QR code written to: $OutputPath"

    # ── 5. Display ────────────────────────────────────────────────────────────
    if (-not $NoDisplay) {
        if ($IsWindows) {
            Start-Process $OutputPath
        } elseif ($IsMacOS) {
            & open $OutputPath
        } else {
            # Linux: try common viewers in order
            $viewer = 'eog', 'feh', 'display', 'xdg-open' |
                      Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
                      Select-Object -First 1
            if ($viewer) {
                & $viewer $OutputPath &
            } else {
                Write-Warning "No image viewer found. File saved to: $OutputPath"
            }
        }
    }

    # Return path for pipeline use
    $OutputPath
}