param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = ".\mkv_scan.csv"
)

# Verifica que ffprobe exista en PATH
$ffprobeCmd = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobeCmd) {
    throw "No encuentro 'ffprobe' en el PATH. Instala FFmpeg y asegúrate de que ffprobe.exe esté disponible."
}

function Get-TagValue {
    param(
        [object]$Tags,
        [string]$Name
    )
    if ($null -ne $Tags -and $Tags.PSObject.Properties.Name -contains $Name) {
        return [string]$Tags.$Name
    }
    return ""
}

function Format-VideoTrack {
    param([object]$s)

    $lang   = Get-TagValue -Tags $s.tags -Name "language"
    $title  = Get-TagValue -Tags $s.tags -Name "title"
    $codec  = [string]$s.codec_name
    $pixfmt = [string]$s.pix_fmt
    $prof   = [string]$s.profile
    $w      = [string]$s.width
    $h      = [string]$s.height

    $parts = @(
        "v:$($s.index)"
        "codec=$codec"
        "profile=$prof"
        "pix_fmt=$pixfmt"
        "res=${w}x${h}"
        "lang=$lang"
        "title=$title"
    ) | Where-Object { $_ -notmatch '=$' }

    return ($parts -join "; ")
}

function Format-AudioTrack {
    param([object]$s)

    $lang     = Get-TagValue -Tags $s.tags -Name "language"
    $title    = Get-TagValue -Tags $s.tags -Name "title"
    $codec    = [string]$s.codec_name
    $channels = [string]$s.channels
    $layout   = [string]$s.channel_layout

    $parts = @(
        "a:$($s.index)"
        "codec=$codec"
        "channels=$channels"
        "layout=$layout"
        "lang=$lang"
        "title=$title"
    ) | Where-Object { $_ -notmatch '=$' }

    return ($parts -join "; ")
}

function Format-SubtitleTrack {
    param([object]$s)

    $lang  = Get-TagValue -Tags $s.tags -Name "language"
    $title = Get-TagValue -Tags $s.tags -Name "title"
    $codec = [string]$s.codec_name

    $parts = @(
        "s:$($s.index)"
        "codec=$codec"
        "lang=$lang"
        "title=$title"
    ) | Where-Object { $_ -notmatch '=$' }

    return ($parts -join "; ")
}

$files = Get-ChildItem -Path $RootPath -Recurse -File -Filter *.mkv

if (-not $files) {
    Write-Warning "No encontré archivos .mkv en: $RootPath"
    exit
}

$results = foreach ($file in $files) {
    try {
        $json = & ffprobe `
            -v quiet `
            -print_format json `
            -show_format `
            -show_streams `
            -- "$($file.FullName)"

        if (-not $json) {
            Write-Warning "ffprobe no devolvió datos: $($file.FullName)"
            continue
        }

        $data = $json | ConvertFrom-Json

        $videoStreams = @($data.streams | Where-Object { $_.codec_type -eq "video" })
        $audioStreams = @($data.streams | Where-Object { $_.codec_type -eq "audio" })
        $subStreams   = @($data.streams | Where-Object { $_.codec_type -eq "subtitle" })

        $videoText = ($videoStreams | ForEach-Object { Format-VideoTrack $_ }) -join " || "
        $audioText = ($audioStreams | ForEach-Object { Format-AudioTrack $_ }) -join " || "
        $subText   = ($subStreams   | ForEach-Object { Format-SubtitleTrack $_ }) -join " || "

        $containerFormat = [string]$data.format.format_name
        $duration        = [string]$data.format.duration
        $bitRate         = [string]$data.format.bit_rate
        $fileTitle       = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        # Resumen estilo inventario, sin reinterpretar etiquetas
        $summaryParts = @($fileTitle)

        if ($videoStreams.Count -gt 0) {
            foreach ($v in $videoStreams) {
                $summaryParts += ([string]$v.codec_name)
            }
        }

        if ($audioStreams.Count -gt 0) {
            foreach ($a in $audioStreams) {
                $lang = Get-TagValue -Tags $a.tags -Name "language"
                $summaryParts += ("{0} {1}" -f [string]$a.codec_name, $lang).Trim()
            }
        }

        if ($subStreams.Count -gt 0) {
            foreach ($s in $subStreams) {
                $lang = Get-TagValue -Tags $s.tags -Name "language"
                $summaryParts += ("sub {0}" -f $lang).Trim()
            }
        }

        [PSCustomObject]@{
            Nombre            = $fileTitle
            Archivo           = $file.Name
            Ruta              = $file.FullName
            Contenedor        = $containerFormat
            DuracionSeg       = $duration
            Bitrate           = $bitRate
            Video_Count       = $videoStreams.Count
            Audio_Count       = $audioStreams.Count
            Subtitulos_Count  = $subStreams.Count
            Video             = $videoText
            Audio             = $audioText
            Subtitulos        = $subText
            Resumen           = ($summaryParts -join " | ")
        }
    }
    catch {
        Write-Warning "Error procesando $($file.FullName): $($_.Exception.Message)"
    }
}

$results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Listo. CSV generado en: $OutputCsv"
Write-Host "Archivos procesados: $($results.Count)"