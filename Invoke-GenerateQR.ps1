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
        [ValidateSet('ASCII', 'UTF-7', 'UTF-8', 'UTF-16', 'UTF-16BE', 'UTF-32', 'UTF-32BE')]
        [string] $Encoding = 'UTF-8',

        [Parameter()]
        [switch] $NoDisplay,

        [Parameter()]
        [switch] $TestLimits
    )
    [uint]$TextLength = 0
    [uint]$BytesLength = 0

    $AllowOverflow = $TestLimits -eq $True
    # Max binary bytes per QR spec v40 for each ECC level
    $qrMaxBytes = @{ L = 2953; M = 2331; Q = 1663; H = 1273 }
    $qrMaxCharacters = @{ L = 4296; M = 3391; Q = 2420; H = 1852 }
    $limitBytes      = $qrMaxBytes[$ErrorCorrection]
    $limitChars      = $qrMaxCharacters[$ErrorCorrection]
    # Determine which QR encoding mode QRCoder will actually use
    $isNumeric      = $Text -cmatch '^[0-9]+$'
    $isAlphanumeric = $Text -cmatch '^[0-9A-Z $%*+\-./:]+$'

    $effectiveLimit = if ($isNumeric) {
        @{ L = 7089; M = 5596; Q = 3993; H = 3057 }[$ErrorCorrection]
    } elseif ($isAlphanumeric) {
        $limitChars   # your existing $qrMaxCharacters table
    } else {
        $limitBytes   # byte mode — use the byte cap
    }

    $measureLength = if ($isNumeric -or $isAlphanumeric) {
        $Text.Length
    } else {
        $enc.GetByteCount($Text)
    }

    if ($measureLength -gt $effectiveLimit) {
        Write-Warning "[Size calculation] The given payload exceeds the maximum size of the QR code standard. The maximum size allowed for the chosen parameters. Not ALPHANUMERIC (A-Z 0-9 `$%*+-./: space (uppercase only) )"
    }

    if($AllowOverflow -eq $False){
        if ($PSCmdlet.ParameterSetName -eq 'Text') {
            $enc = [System.Text.Encoding]::GetEncoding($Encoding)
             if (-not ($enc)) {
                throw 'Wrong encoding {0}' -f $Encoding
            }
            $byteCount = $enc.GetByteCount($Text)
            $TextLength = $Text.Length
            if ($byteCount -gt $limitChars) {
                
                [System.Management.Automation.ErrorRecord]$ErrorEntry = [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Text using encoding $Encoding encodes to $byteCount bytes, $TextLength characters. Max for ECC '$ErrorCorrection' is $limitChars bytes."),
                        'QRTextTooLong',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $Text
                    )
          
                 throw $ErrorEntry
                              
                
            }
        } else {
            $BytesLength = $Bytes.Length
            if ($Bytes.Length -gt $limitBytes) {
                
                    [System.Management.Automation.ErrorRecord]$ErrorEntry = [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            "Byte array is $($Bytes.Length) bytes. Max for ECC '$ErrorCorrection' is $limitBytes bytes."),
                        'QRByteArrayTooLong',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $Bytes
                    )
        
                    throw $ErrorEntry
            }
        }
   }
    Write-Verbose "Resolve / create output path"
    # ── 1. Resolve / create output path ──────────────────────────────────────
    if (-not $OutputPath) {
        $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "qr_$(Get-Random).png"
    }
    Write-Verbose "Ensure QRCoder is available"
    # ── 2. Ensure QRCoder is available ────────────────────────────────────────
    $cacheDir   = Join-Path $env:LOCALAPPDATA 'PSQRCoder'
    $markerFile = Join-Path $cacheDir 'qrcoder.loaded'
    Write-Verbose "Locate DLL (may already be cached from a previous run)"
    # Locate DLL (may already be cached from a previous run)
    $dll = Get-ChildItem -Path $cacheDir -Filter 'QRCoder.dll' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName

    if (-not $dll) {
        Write-Host '[QRCoder] First run — downloading via NuGet...' -ForegroundColor Cyan
        Write-Verbose '[QRCoder] First run — downloading via NuGet...' 
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
        $restoreArgsStr = $restoreArgs -join ' '
        Write-Verbose "dotnet $restoreArgsStr"
        Write-Host "dotnet $restoreArgsStr" -f DarkCyan
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
        Write-Verbose "generator.CreateQrCode(<Bytes>$BytesLength bytes, $ErrorCorrection)"
        $generator.CreateQrCode($Bytes, $ecLevel)
    } else {
        Write-Verbose "generator.CreateQrCode(<Text>$TextLength chars, $ErrorCorrection)"
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
