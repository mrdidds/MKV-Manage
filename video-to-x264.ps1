param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $false)]
    [string]$FfmpegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$FfprobePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$Execute,

    [Parameter(Mandatory = $false)]
    [switch]$Overwrite,

    [Parameter(Mandatory = $false)]
    [switch]$Downscale1080p,

    [Parameter(Mandatory = $false)]
    [string]$InputPrefix = "__",

    [Parameter(Mandatory = $false)]
    [string]$OutputPrefix = "___",

    [Parameter(Mandatory = $false)]
    [int]$Crf = 18,

    [Parameter(Mandatory = $false)]
    [string]$Preset = "slow",

    [Parameter(Mandatory = $false)]
    [string]$ReportCsv = ""
)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Resolve-Tool {
    param(
        [string]$CustomPath,
        [string]$CommandName,
        [string]$FriendlyName
    )

    if ($CustomPath -and (Test-Path $CustomPath)) {
        return (Resolve-Path $CustomPath).Path
    }

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "No encuentro '$FriendlyName'. Usa la ruta explícita o agrégalo al PATH."
}

function Resolve-InputFiles {
    param(
        [string]$Path,
        [bool]$UseRecurse,
        [string]$RequiredPrefix,
        [string]$BlockedPrefix
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop

    if ($item.PSIsContainer) {
        if ($UseRecurse) {
            $allFiles = @(Get-ChildItem -LiteralPath $item.FullName -Filter *.mkv -File -Recurse)
        }
        else {
            $allFiles = @(Get-ChildItem -LiteralPath $item.FullName -Filter *.mkv -File)
        }
    }
    else {
        if ($item.Extension -ne ".mkv") {
            throw "El archivo de entrada debe ser .mkv"
        }
        $allFiles = @($item)
    }

    if ([string]::IsNullOrWhiteSpace($RequiredPrefix)) {
        # Originales = no empiezan con "_"
        $filtered = @(
            $allFiles | Where-Object {
                $_.Name -notmatch '^_'
            }
        )
    }
    else {
        $filtered = @(
            $allFiles | Where-Object {
                $_.Name.StartsWith($RequiredPrefix) -and -not $_.Name.StartsWith($BlockedPrefix)
            }
        )
    }

    return $filtered
}

function Get-OutputName {
    param(
        [string]$OriginalName,
        [string]$InputPrefix,
        [string]$OutputPrefix
    )

    if ([string]::IsNullOrWhiteSpace($InputPrefix)) {
        return $OutputPrefix + $OriginalName
    }

    if ($OriginalName.StartsWith($InputPrefix)) {
        return $OutputPrefix + $OriginalName.Substring($InputPrefix.Length)
    }

    return $OutputPrefix + $OriginalName
}

function Get-TagValue {
    param(
        [object]$Tags,
        [string[]]$Names
    )

    if ($null -eq $Tags) { return "" }

    foreach ($name in $Names) {
        foreach ($prop in $Tags.PSObject.Properties) {
            if ($prop.Name -ieq $name) {
                return [string]$prop.Value
            }
        }
    }

    return ""
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)

    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join ' '
}

function Get-DurationSeconds {
    param([object]$ProbeData)

    if ($ProbeData.format -and $ProbeData.format.duration) {
        return [double]$ProbeData.format.duration
    }

    return 0
}

function Show-ProgressLine {
    param(
        [string]$Label,
        [int]$Percent
    )

    $safeLabel = $Label
    if ($safeLabel.Length -gt 60) {
        $safeLabel = $safeLabel.Substring(0, 60)
    }

    $line = "{0} .... {1,3}%%" -f $safeLabel, $Percent
    [Console]::Write(("`r{0,-95}" -f $line))
}

function Invoke-FfmpegWithProgress {
    param(
        [string]$FfmpegExe,
        [string[]]$FfmpegArgs,
        [string]$Label,
        [double]$DurationSeconds
    )

    $allArgs = @(
        "-hide_banner"
        "-loglevel"; "error"
        "-progress"; "pipe:1"
        "-nostats"
    ) + $FfmpegArgs

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegExe
    $psi.Arguments = ConvertTo-ArgumentString -Arguments $allArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [void]$proc.Start()

    $lastPercent = -1

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()

        if ($line -match '^out_time=(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$') {
            $hh = [int]$matches[1]
            $mm = [int]$matches[2]
            $ss = [int]$matches[3]
            $ff = if ($matches[4]) { [double]("0." + $matches[4]) } else { 0 }

            $currentSeconds = ($hh * 3600) + ($mm * 60) + $ss + $ff

            if ($DurationSeconds -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($currentSeconds / $DurationSeconds) * 100))
                if ($percent -ne $lastPercent) {
                    Show-ProgressLine -Label $Label -Percent $percent
                    $lastPercent = $percent
                }
            }
        }
        elseif ($line -eq 'progress=end') {
            Show-ProgressLine -Label $Label -Percent 100
        }
    }

    $stdErr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        Write-Host ""
        throw "FFmpeg falló para '$Label'. $stdErr"
    }

    Write-Host ""
}

# ------------------------------------------------------------
# Resolve tools
# ------------------------------------------------------------
$ffmpegCmd  = Resolve-Tool -CustomPath $FfmpegPath  -CommandName "ffmpeg"  -FriendlyName "ffmpeg"
$ffprobeCmd = Resolve-Tool -CustomPath $FfprobePath -CommandName "ffprobe" -FriendlyName "ffprobe"

# ------------------------------------------------------------
# Resolve input files
# ------------------------------------------------------------
$files = Resolve-InputFiles `
    -Path $InputPath `
    -UseRecurse:$Recurse.IsPresent `
    -RequiredPrefix $InputPrefix `
    -BlockedPrefix $OutputPrefix

if (-not $files -or $files.Count -eq 0) {
    throw "No encontré archivos .mkv válidos para procesar con el prefijo de entrada '$InputPrefix'."
}

$inputItem = Get-Item -LiteralPath $InputPath
$reportBaseName = if ($inputItem.PSIsContainer) { $inputItem.Name } else { $inputItem.BaseName }
$timestamp = Get-Date -Format "HHmm"

if ([string]::IsNullOrWhiteSpace($ReportCsv)) {
    $reportDir = if ($inputItem.PSIsContainer) { $inputItem.FullName } else { $inputItem.Directory.FullName }
    $ReportCsv = Join-Path $reportDir ("{0}_x264_{1}.csv" -f $reportBaseName, $timestamp)
}
else {
    $reportDir = Split-Path -Parent $ReportCsv
    if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
        New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "Conversión HEVC/x265 -> H.264/x264"
Write-Host "Entrada       : $InputPath"
Write-Host "Modo          : $(if ($Execute) { 'EJECUCION REAL' } else { 'DRY RUN' })"
Write-Host "Resolución    : $(if ($Downscale1080p) { 'Forzar 1080p' } else { 'Conservar original' })"
Write-Host "CRF / Preset  : $Crf / $Preset"
Write-Host "Prefijos      : '$InputPrefix' -> '$OutputPrefix'"
Write-Host "Total archivos: $($files.Count)"
Write-Host "============================================"
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$current = 0

foreach ($file in $files) {
    $current++
    Write-Host ("[{0}/{1}] Analizando: {2}" -f $current, $files.Count, $file.FullName)

    try {
        $json = & $ffprobeCmd `
            -v quiet `
            -print_format json `
            -show_streams `
            -show_format `
            -- "$($file.FullName)"

        if (-not $json) {
            throw "ffprobe no devolvió datos JSON"
        }

        $data = $json | ConvertFrom-Json
        $videoStreams = @($data.streams | Where-Object { $_.codec_type -eq "video" })

        if ($videoStreams.Count -eq 0) {
            $result = [PSCustomObject]@{
                Archivo          = $file.Name
                Ruta             = $file.FullName
                Estado           = "SKIP"
                CodecVideo       = ""
                Resolucion       = ""
                Salida           = ""
                AccionVideo      = ""
                Notas            = "No se detectó video"
            }
            $results.Add($result)
            Write-Host "          Estado    : SKIP"
            Write-Host "          Motivo    : No se detectó video"
            continue
        }

        $mainVideo = $videoStreams | Select-Object -First 1
        $videoCodec = [string]$mainVideo.codec_name
        $width = if ($null -ne $mainVideo.width) { [int]$mainVideo.width } else { 0 }
        $height = if ($null -ne $mainVideo.height) { [int]$mainVideo.height } else { 0 }

        $videoTitle = Get-TagValue -Tags $mainVideo.tags -Names @("title", "TITLE")

        if ($videoCodec -ne "hevc") {
            $result = [PSCustomObject]@{
                Archivo          = $file.Name
                Ruta             = $file.FullName
                Estado           = "SKIP"
                CodecVideo       = $videoCodec
                Resolucion       = "${width}x${height}"
                Salida           = ""
                AccionVideo      = "No convertir"
                Notas            = "El video no es HEVC/x265"
            }
            $results.Add($result)
            Write-Host "          Estado    : SKIP"
            Write-Host "          Motivo    : El video no es HEVC/x265"
            continue
        }

        $outputPath = Join-Path $file.Directory.FullName (
            Get-OutputName -OriginalName $file.Name -InputPrefix $InputPrefix -OutputPrefix $OutputPrefix
        )

        $actionText = if ($Downscale1080p) {
            "Convertir a x264 y bajar a 1080p"
        }
        else {
            "Convertir a x264 conservando resolución"
        }

        $result = [PSCustomObject]@{
            Archivo          = $file.Name
            Ruta             = $file.FullName
            Estado           = "OK"
            CodecVideo       = $videoCodec
            Resolucion       = "${width}x${height}"
            Salida           = $outputPath
            AccionVideo      = $actionText
            Notas            = if ([string]::IsNullOrWhiteSpace($videoTitle)) { "" } else { "Track title: $videoTitle" }
        }
        $results.Add($result)

        Write-Host "          Estado    : OK"
        Write-Host "          Video     : codec=$videoCodec res=${width}x${height}"
        Write-Host "          Acción    : $actionText"
        Write-Host "          Salida    : $outputPath"

        if (-not $Execute) {
            continue
        }

        if ((Test-Path $outputPath) -and (-not $Overwrite)) {
            Write-Warning "El archivo ya existe y no se usó -Overwrite: $outputPath"
            continue
        }

        if ($Overwrite -and (Test-Path $outputPath)) {
            Remove-Item -LiteralPath $outputPath -Force
        }

        $args = @()
        $args += "-y"
        $args += "-i"
        $args += $file.FullName

        # Mapear todo lo importante
        $args += "-map"; $args += "0:v:0"
        $args += "-map"; $args += "0:a?"
        $args += "-map"; $args += "0:s?"
        $args += "-map"; $args += "0:t?"
        $args += "-map_metadata"; $args += "0"
        $args += "-map_chapters"; $args += "0"

        # Video a x264
        if ($Downscale1080p) {
            $args += "-vf"
            $args += "scale='if(gt(ih,1080),-2,iw)':'if(gt(ih,1080),1080,ih)':flags=lanczos,format=yuv420p"
        }
        else {
            $args += "-vf"
            $args += "format=yuv420p"
        }

        $args += "-c:v"; $args += "libx264"
        $args += "-preset"; $args += $Preset
        $args += "-crf"; $args += $Crf

        # Copiar audio/subs/attachments
        $args += "-c:a"; $args += "copy"
        $args += "-c:s"; $args += "copy"
        $args += "-c:t"; $args += "copy"

        $args += "-max_muxing_queue_size"; $args += "4096"
        $args += $outputPath

        $durationSeconds = Get-DurationSeconds -ProbeData $data
        Invoke-FfmpegWithProgress `
            -FfmpegExe $ffmpegCmd `
            -FfmpegArgs $args `
            -Label $file.BaseName `
            -DurationSeconds $durationSeconds
    }
    catch {
        $errorResult = [PSCustomObject]@{
            Archivo          = $file.Name
            Ruta             = $file.FullName
            Estado           = "ERROR"
            CodecVideo       = ""
            Resolucion       = ""
            Salida           = ""
            AccionVideo      = ""
            Notas            = $_.Exception.Message
        }

        $results.Add($errorResult)
        Write-Warning "Error: $($file.FullName) -> $($_.Exception.Message)"
    }
}

$results | Export-Csv -Path $ReportCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host "Proceso terminado"
Write-Host "Reporte CSV : $ReportCsv"
Write-Host "Modo        : $(if ($Execute) { 'EJECUCION REAL' } else { 'DRY RUN' })"
Write-Host "============================================"
Write-Host ""