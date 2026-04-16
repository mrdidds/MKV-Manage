param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = ".\mkv_scan.csv",

    [Parameter(Mandatory = $false)]
    [string]$FfprobePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSubfolders
)

function Resolve-Ffprobe {
    param([string]$CustomPath)

    if ($CustomPath -and (Test-Path $CustomPath)) {
        return (Resolve-Path $CustomPath).Path
    }

    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $portableCandidates = @(
        (Join-Path $scriptDir 'ffprobe.exe'),
        (Join-Path $scriptDir 'bin\ffprobe.exe'),
        (Join-Path $scriptDir '..\ffprobe.exe'),
        (Join-Path $scriptDir '..\bin\ffprobe.exe'),
        (Join-Path $scriptDir '..\..\ffprobe.exe'),
        (Join-Path $scriptDir '..\..\bin\ffprobe.exe')
    )

    foreach ($candidate in $portableCandidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    $searchRoot = Split-Path $scriptDir -Parent
    if ([string]::IsNullOrWhiteSpace($searchRoot)) {
        $searchRoot = $scriptDir
    }

    $found = Get-ChildItem -Path $searchRoot -Filter ffprobe.exe -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($found) {
        return $found.FullName
    }

    throw "No encuentro 'ffprobe'. Usa -FfprobePath, agrégalo al PATH o colócalo cerca del script."
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

function Convert-CodecToFriendlyName {
    param(
        [string]$CodecName,
        [string]$CodecType
    )

    $codec = ([string]$CodecName).ToLowerInvariant()
    $type  = ([string]$CodecType).ToLowerInvariant()

    switch ($codec) {
        'hevc'                 { return 'x265' }
        'h264'                 { return 'x264' }
        'av1'                  { return 'av1' }
        'mpeg4'                { return 'mpeg4' }
        'vp9'                  { return 'vp9' }
        'aac'                  { return 'aac' }
        'flac'                 { return 'flac' }
        'mp3'                  { return 'mp3' }
        'ac3'                  { return 'ac3' }
        'eac3'                 { return 'eac3' }
        'dts'                  { return 'dts' }
        'truehd'               { return 'truehd' }
        'opus'                 { return 'opus' }
        'vorbis'               { return 'vorbis' }
        'ass'                  { return 'ass' }
        'ssa'                  { return 'ssa' }
        'subrip'               { return 'srt' }
        'srt'                  { return 'srt' }
        'webvtt'               { return 'vtt' }
        'mov_text'             { return 'mov_text' }
        'hdmv_pgs_subtitle'    { return 'pgs' }
        'dvd_subtitle'         { return 'vobsub' }
        default {
            if ([string]::IsNullOrWhiteSpace($codec)) {
                return ''
            }
            return $codec
        }
    }
}

function Format-VideoTrack {
    param([object]$s)

    $lang   = Get-TagValue -Tags $s.tags -Names @('language', 'LANGUAGE')
    $title  = Get-TagValue -Tags $s.tags -Names @('title', 'TITLE')
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

    return ($parts -join '; ')
}

function Format-AudioTrack {
    param([object]$s)

    $lang     = Get-TagValue -Tags $s.tags -Names @('language', 'LANGUAGE')
    $title    = Get-TagValue -Tags $s.tags -Names @('title', 'TITLE')
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

    return ($parts -join '; ')
}

function Format-SubtitleTrack {
    param([object]$s)

    $lang  = Get-TagValue -Tags $s.tags -Names @('language', 'LANGUAGE')
    $title = Get-TagValue -Tags $s.tags -Names @('title', 'TITLE')
    $codec = [string]$s.codec_name

    $parts = @(
        "s:$($s.index)"
        "codec=$codec"
        "lang=$lang"
        "title=$title"
    ) | Where-Object { $_ -notmatch '=$' }

    return ($parts -join '; ')
}

$ffprobeCmd = Resolve-Ffprobe -CustomPath $FfprobePath

if ($IncludeSubfolders) {
    $files = Get-ChildItem -Path $RootPath -Recurse -File -Filter *.mkv
}
else {
    $files = Get-ChildItem -Path $RootPath -File -Filter *.mkv
}

if (-not $files) {
    Write-Warning "No encontré archivos .mkv en: $RootPath"
    exit
}

$total = $files.Count
$current = 0
$rawResults = New-Object System.Collections.Generic.List[object]
$maxVideoCount = 0
$maxAudioCount = 0
$maxSubCount = 0

foreach ($file in $files) {
    $current++
    Write-Host ("[{0}/{1}] Analizando: {2}" -f $current, $total, $file.Name)

    try {
        $json = & $ffprobeCmd `
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

        $videoStreams = @($data.streams | Where-Object { $_.codec_type -eq 'video' })
        $audioStreams = @($data.streams | Where-Object { $_.codec_type -eq 'audio' })
        $subStreams   = @($data.streams | Where-Object { $_.codec_type -eq 'subtitle' })

        $videoFormats = @($videoStreams | ForEach-Object { Convert-CodecToFriendlyName -CodecName $_.codec_name -CodecType 'video' })
        $audioFormats = @($audioStreams | ForEach-Object { Convert-CodecToFriendlyName -CodecName $_.codec_name -CodecType 'audio' })
        $subFormats   = @($subStreams   | ForEach-Object { Convert-CodecToFriendlyName -CodecName $_.codec_name -CodecType 'subtitle' })

        $videoText = ($videoStreams | ForEach-Object { Format-VideoTrack $_ }) -join ' || '
        $audioText = ($audioStreams | ForEach-Object { Format-AudioTrack $_ }) -join ' || '
        $subText   = ($subStreams   | ForEach-Object { Format-SubtitleTrack $_ }) -join ' || '

        $containerFormat = [string]$data.format.format_name
        $duration        = [string]$data.format.duration
        $bitRate         = [string]$data.format.bit_rate
        $fileTitle       = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        $summaryParts = @($fileTitle)
        foreach ($vf in $videoFormats) { if ($vf) { $summaryParts += $vf } }
        foreach ($af in $audioFormats) { if ($af) { $summaryParts += $af } }
        foreach ($sf in $subFormats)   { if ($sf) { $summaryParts += ("sub {0}" -f $sf) } }

        $maxVideoCount = [Math]::Max($maxVideoCount, $videoFormats.Count)
        $maxAudioCount = [Math]::Max($maxAudioCount, $audioFormats.Count)
        $maxSubCount   = [Math]::Max($maxSubCount,   $subFormats.Count)

        $rawResults.Add([PSCustomObject]@{
            Nombre             = $fileTitle
            Archivo            = $file.Name
            Ruta               = $file.FullName
            Contenedor         = $containerFormat
            DuracionSeg        = $duration
            Bitrate            = $bitRate
            Video_Count        = $videoStreams.Count
            Audio_Count        = $audioStreams.Count
            Subtitulos_Count   = $subStreams.Count
            Video_Formatos     = ($videoFormats -join ' | ')
            Audio_Formatos     = ($audioFormats -join ' | ')
            Subtitulos_Formatos= ($subFormats -join ' | ')
            Video_Detalle      = $videoText
            Audio_Detalle      = $audioText
            Subtitulos_Detalle = $subText
            Resumen            = ($summaryParts -join ' | ')
            _VideoFormats      = $videoFormats
            _AudioFormats      = $audioFormats
            _SubFormats        = $subFormats
        })
    }
    catch {
        Write-Warning "Error procesando $($file.FullName): $($_.Exception.Message)"
    }
}

$finalResults = foreach ($item in $rawResults) {
    $ordered = [ordered]@{
        Nombre              = $item.Nombre
        Archivo             = $item.Archivo
        Ruta                = $item.Ruta
        Contenedor          = $item.Contenedor
        DuracionSeg         = $item.DuracionSeg
        Bitrate             = $item.Bitrate
        Video_Count         = $item.Video_Count
        Audio_Count         = $item.Audio_Count
        Subtitulos_Count    = $item.Subtitulos_Count
        Video_Formatos      = $item.Video_Formatos
        Audio_Formatos      = $item.Audio_Formatos
        Subtitulos_Formatos = $item.Subtitulos_Formatos
    }

    for ($i = 0; $i -lt $maxVideoCount; $i++) {
        $ordered[("Video_{0:D2}_Formato" -f ($i + 1))] = if ($i -lt $item._VideoFormats.Count) { $item._VideoFormats[$i] } else { '' }
    }

    for ($i = 0; $i -lt $maxAudioCount; $i++) {
        $ordered[("Audio_{0:D2}_Formato" -f ($i + 1))] = if ($i -lt $item._AudioFormats.Count) { $item._AudioFormats[$i] } else { '' }
    }

    for ($i = 0; $i -lt $maxSubCount; $i++) {
        $ordered[("Sub_{0:D2}_Formato" -f ($i + 1))] = if ($i -lt $item._SubFormats.Count) { $item._SubFormats[$i] } else { '' }
    }

    $ordered['Video_Detalle'] = $item.Video_Detalle
    $ordered['Audio_Detalle'] = $item.Audio_Detalle
    $ordered['Subtitulos_Detalle'] = $item.Subtitulos_Detalle
    $ordered['Resumen'] = $item.Resumen

    [PSCustomObject]$ordered
}

$finalResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host "Listo. CSV generado en: $OutputCsv"
Write-Host "Archivos procesados: $($finalResults.Count)"
Write-Host "ffprobe usado: $ffprobeCmd"
