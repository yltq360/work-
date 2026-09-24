#requires -Version 5.1

<#
MOV to GIF converter.

Quality policy:
- No scale, crop, or fps filter is used.
- Frames keep their source dimensions and timestamps as far as GIF permits.
- GIF stores frame delays in centiseconds, so some source rates (for example
  60 fps) cannot be represented exactly. FFmpeg must quantize those delays.
- GIF has a 256-color palette by design. palettegen + paletteuse improves the
  color conversion but cannot make GIF visually lossless.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $InputFiles,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {
    # Output encoding is cosmetic; conversion must still work in older hosts.
}

function Resolve-NativeTool {
    param([Parameter(Mandatory = $true)][string] $BaseName)

    $localPath = Join-Path -Path $PSScriptRoot -ChildPath ($BaseName + '.exe')
    if ([System.IO.File]::Exists($localPath)) {
        return [System.IO.Path]::GetFullPath($localPath)
    }

    $command = Get-Command ($BaseName + '.exe') -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Invoke-MediaProbe {
    param(
        [Parameter(Mandatory = $true)][string] $ProbePath,
        [Parameter(Mandatory = $true)][string] $MediaPath
    )

    $probeArguments = @(
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,avg_frame_rate,r_frame_rate:format=duration',
        '-of', 'json',
        $MediaPath
    )

    $probeLines = @(& $ProbePath @probeArguments 2>&1)
    $probeExitCode = $LASTEXITCODE
    $probeText = ($probeLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($probeExitCode -ne 0) {
        throw "ffprobe failed (exit code $probeExitCode):`n$probeText"
    }

    try {
        $probe = $probeText | ConvertFrom-Json
    } catch {
        throw "ffprobe returned invalid JSON:`n$probeText"
    }

    if (($null -eq $probe.streams) -or (@($probe.streams).Count -eq 0)) {
        throw 'ffprobe did not find a video stream.'
    }

    return [PSCustomObject]@{
        Stream   = @($probe.streams)[0]
        Format   = $probe.format
        RawJson  = $probeText
    }
}

function Convert-RationalToDouble {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [double]::NaN
    }

    $parts = $Value.Split('/')
    if ($parts.Count -ne 2) {
        $number = 0.0
        if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref] $number)) {
            return $number
        }
        return [double]::NaN
    }

    $numerator = 0.0
    $denominator = 0.0
    $okNumerator = [double]::TryParse($parts[0], [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref] $numerator)
    $okDenominator = [double]::TryParse($parts[1], [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref] $denominator)

    if ((-not $okNumerator) -or (-not $okDenominator) -or ($denominator -eq 0.0)) {
        return [double]::NaN
    }

    return $numerator / $denominator
}

function Format-Fps {
    param($Stream)

    $avgText = [string] $Stream.avg_frame_rate
    $realText = [string] $Stream.r_frame_rate
    $fps = Convert-RationalToDouble -Value $avgText
    if ([double]::IsNaN($fps) -or ($fps -le 0)) {
        $fps = Convert-RationalToDouble -Value $realText
    }

    $numericText = 'unknown'
    if ((-not [double]::IsNaN($fps)) -and ($fps -gt 0)) {
        $numericText = $fps.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return "$numericText FPS (avg_frame_rate=$avgText; r_frame_rate=$realText)"
}

function Format-Duration {
    param([string] $Value)

    $seconds = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref] $seconds)) {
        return ($seconds.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) + ' s')
    }
    return 'unknown'
}

function Format-FileSize {
    param([long] $Bytes)

    $mib = $Bytes / 1MB
    return ('{0:N0} bytes ({1:N2} MiB)' -f $Bytes, $mib)
}

function Invoke-FfmpegStep {
    param(
        [Parameter(Mandatory = $true)][string] $FfmpegPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $StepName
    )

    & $FfmpegPath @Arguments
    $ffmpegExitCode = $LASTEXITCODE
    if ($ffmpegExitCode -ne 0) {
        throw "$StepName failed (FFmpeg exit code $ffmpegExitCode). The complete FFmpeg output is shown above."
    }
}

function Get-PassthroughTimingArguments {
    param([Parameter(Mandatory = $true)][string] $FfmpegPath)

    $helpLines = @(& $FfmpegPath -hide_banner -h full 2>&1)
    $helpExitCode = $LASTEXITCODE
    $helpText = ($helpLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($helpExitCode -ne 0) {
        throw "Unable to inspect FFmpeg timing options (exit code $helpExitCode)."
    }

    if ($helpText.Contains('-fps_mode')) {
        return [string[]] @('-fps_mode', 'passthrough')
    }
    if ($helpText.Contains('-vsync')) {
        return [string[]] @('-vsync', '0')
    }

    throw 'This FFmpeg build exposes neither -fps_mode nor -vsync; timestamp passthrough cannot be requested safely.'
}

function Convert-OneMov {
    param(
        [Parameter(Mandatory = $true)][string] $InputPath,
        [Parameter(Mandatory = $true)][string] $FfmpegPath,
        [Parameter(Mandatory = $true)][string] $FfprobePath,
        [Parameter(Mandatory = $true)][string[]] $TimingArguments,
        [Parameter(Mandatory = $true)][bool] $Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Input file does not exist: $InputPath"
    }

    $resolvedInput = (Resolve-Path -LiteralPath $InputPath).ProviderPath
    if ([System.IO.Path]::GetExtension($resolvedInput) -ine '.mov') {
        throw "Only .mov input is supported: $resolvedInput"
    }

    $directory = [System.IO.Path]::GetDirectoryName($resolvedInput)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    $outputPath = [System.IO.Path]::Combine($directory, $baseName + '.gif')

    if ([System.IO.File]::Exists($outputPath) -and (-not $Overwrite)) {
        throw "Output already exists: $outputPath`nUse -Force to overwrite it explicitly."
    }

    $inputProbe = Invoke-MediaProbe -ProbePath $FfprobePath -MediaPath $resolvedInput
    Write-Host ''
    Write-Host ('输入文件：{0}' -f $resolvedInput)
    Write-Host ('原分辨率：{0}x{1}' -f $inputProbe.Stream.width, $inputProbe.Stream.height)
    Write-Host ('原 FPS：  {0}' -f (Format-Fps -Stream $inputProbe.Stream))
    Write-Host ('原时长：  {0}' -f (Format-Duration -Value ([string] $inputProbe.Format.duration)))

    $token = [Guid]::NewGuid().ToString('N')
    $palettePath = [System.IO.Path]::Combine($directory, ".mov-to-gif-$token-palette.png")
    $temporaryGif = [System.IO.Path]::Combine($directory, ".mov-to-gif-$token-partial.gif")
    $completed = $false

    try {
        # Two passes avoid buffering a full-resolution video branch while the
        # palette is being generated. No scale/fps/crop filter is present.
        $paletteArguments = @(
            '-hide_banner', '-nostdin', '-v', 'info',
            '-i', $resolvedInput,
            '-map', '0:v:0',
            '-vf', 'palettegen=stats_mode=full',
            '-frames:v', '1',
            '-update', '1',
            '-an', '-y',
            $palettePath
        )
        Invoke-FfmpegStep -FfmpegPath $FfmpegPath -Arguments $paletteArguments -StepName 'Palette generation'

        $gifArguments = @(
            '-hide_banner', '-nostdin', '-v', 'info',
            '-i', $resolvedInput,
            '-i', $palettePath,
            '-filter_complex', '[0:v:0][1:v:0]paletteuse=dither=sierra2_4a[out]',
            '-map', '[out]',
            '-an'
        ) + $TimingArguments + @(
            '-loop', '0',
            '-y',
            $temporaryGif
        )
        Invoke-FfmpegStep -FfmpegPath $FfmpegPath -Arguments $gifArguments -StepName 'GIF encoding'

        if (-not [System.IO.File]::Exists($temporaryGif)) {
            throw 'FFmpeg reported success, but the temporary GIF was not created.'
        }

        # Validate the temporary GIF before replacing an existing output. This
        # keeps -Force from destroying a known-good GIF when validation fails.
        $outputProbe = Invoke-MediaProbe -ProbePath $FfprobePath -MediaPath $temporaryGif
        $outputItem = Get-Item -LiteralPath $temporaryGif
        $outputBytes = [long] $outputItem.Length
        if (($inputProbe.Stream.width -ne $outputProbe.Stream.width) -or
            ($inputProbe.Stream.height -ne $outputProbe.Stream.height)) {
            throw ('Resolution verification failed: source {0}x{1}, GIF {2}x{3}.' -f
                $inputProbe.Stream.width, $inputProbe.Stream.height,
                $outputProbe.Stream.width, $outputProbe.Stream.height)
        }

        Move-Item -LiteralPath $temporaryGif -Destination $outputPath -Force:$Overwrite
        $completed = $true

        Write-Host ''
        Write-Host ('输出文件：    {0}' -f $outputPath)
        Write-Host ('GIF 分辨率： {0}x{1}' -f $outputProbe.Stream.width, $outputProbe.Stream.height)
        Write-Host ('GIF 时长：   {0}' -f (Format-Duration -Value ([string] $outputProbe.Format.duration)))
        Write-Host ('GIF 大小：   {0}' -f (Format-FileSize -Bytes $outputBytes))
        Write-Host 'Result: PASS (resolution matches; no scale/fps/crop filter was used).' -ForegroundColor Green
    } finally {
        if ([System.IO.File]::Exists($palettePath)) {
            Remove-Item -LiteralPath $palettePath -Force -ErrorAction SilentlyContinue
        }
        if ((-not $completed) -and [System.IO.File]::Exists($temporaryGif)) {
            Remove-Item -LiteralPath $temporaryGif -Force -ErrorAction SilentlyContinue
        }
    }
}

$ffmpeg = Resolve-NativeTool -BaseName 'ffmpeg'
$ffprobe = Resolve-NativeTool -BaseName 'ffprobe'

if (($null -eq $ffmpeg) -or ($null -eq $ffprobe)) {
    Write-Host 'ERROR: FFmpeg is not available.' -ForegroundColor Red
    Write-Host 'Place both ffmpeg.exe and ffprobe.exe next to this script, or add both tools to the system PATH.'
    if ($null -eq $ffmpeg) { Write-Host 'Missing: ffmpeg.exe' }
    if ($null -eq $ffprobe) { Write-Host 'Missing: ffprobe.exe' }
    exit 2
}

if (($null -eq $InputFiles) -or ($InputFiles.Count -eq 0)) {
    Write-Host 'Usage:'
    Write-Host '  Drag one or more MOV files onto mov-to-gif.bat'
    Write-Host '  mov-to-gif.bat "D:\Videos\demo.mov"'
    Write-Host '  mov-to-gif.bat -Force "D:\Videos\demo.mov"'
    exit 2
}

try {
    $timingArguments = Get-PassthroughTimingArguments -FfmpegPath $ffmpeg
} catch {
    Write-Host 'ERROR: This FFmpeg build is not compatible with safe timestamp passthrough.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 2
}

$failures = 0
foreach ($inputFile in $InputFiles) {
    try {
        Convert-OneMov -InputPath $inputFile -FfmpegPath $ffmpeg -FfprobePath $ffprobe `
            -TimingArguments $timingArguments -Overwrite $Force.IsPresent
    } catch {
        $failures++
        Write-Host ''
        Write-Host ('FAILED: {0}' -f $inputFile) -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host ("Completed with {0} failure(s)." -f $failures) -ForegroundColor Red
    exit 1
}

Write-Host ("Completed successfully: {0} file(s)." -f $InputFiles.Count) -ForegroundColor Green
exit 0
