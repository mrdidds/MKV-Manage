param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $false)]
    [string]$MkvmergePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$Execute,

    [Parameter(Mandatory = $false)]
    [switch]$Overwrite,

    [Parameter(Mandatory = $false)]
    [string]$ReportCsv = ""
)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Normalize-Text {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $normalized = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder

    foreach ($ch in $normalized.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }

    return $sb.ToString()
}

function Test-IsJapanese {
    param(
        [string]$Language,
        [string]$TrackName
    )

    $lang = Normalize-Text $Language
    $name = Normalize-Text $TrackName

    if ($lang -match '^(ja|jpn|jp)$') { return $true }
    if ($name -match '\bjapanese\b|\bjapones\b|\bjpn\b|\boriginal\b') { return $true }

    return $false
}

function Test-IsLatino {
    param(
        [string]$Language,
        [string]$TrackName
    )

    $lang = Normalize-Text $Language
    $name = Normalize-Text $TrackName

    if ($name -match 'latino|latam|latin america|latinoamerica|spanish latin|espanol latino|audio latino') { return $true }
    if ($lang -match '^(es-la|spa-la|es-mx)$') { return $true }

    return $false
}

function Test-IsCastilian {
    param(
        [string]$Language,
        [string]$TrackName
    )

    $name = Normalize-Text $TrackName

    if ($name -match 'castellano|espana|spanish spain|castilian') { return $true }

    return $false
}

function Test-IsEnglish {
    param(
        [string]$Language,
        [string]$TrackName
    )

    $lang = Normalize-Text $Language
    $name = Normalize-Text $TrackName

    if ($lang -match '^(en|eng)$') { return $true }
    if ($name -match '\benglish\b|\bingles\b') { return $true }

    return $false
}

function Resolve-Mkvmerge {
    param([string]$CustomPath)

    if ($CustomPath -and (Test-Path $CustomPath)) {
        return (Resolve-Path $CustomPath).Path
    }

    $cmd = Get-Command mkvmerge -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "No encuentro 'mkvmerge'. Usa -MkvmergePath 'C:\ruta\mkvmerge.exe' o agrégalo al PATH."
}

function Resolve-InputFiles {
    param(
        [string]$Path,
        [bool]$UseRecurse
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

    # Ignorar archivos ya purgados que empiezan con "_"
    $filtered = @(
        $allFiles | Where-Object {
            $_.Name -notmatch '^_'
        }
    )

    return $filtered
}

function Get-OutputName {
    param([string]$OriginalName)

    return "_$OriginalName"
}

# ------------------------------------------------------------
# Resolver mkvmerge
# ------------------------------------------------------------
$mkvmergeCmd = Resolve-Mkvmerge -CustomPath $MkvmergePath

# ------------------------------------------------------------
# Resolver archivos
# ------------------------------------------------------------
$files = Resolve-InputFiles -Path $InputPath -UseRecurse:$Recurse.IsPresent

if (-not $files -or $files.Count -eq 0) {
    throw "No encontré archivos .mkv para procesar."
}

$inputItem = Get-Item -LiteralPath $InputPath
$reportBaseName = if ($inputItem.PSIsContainer) { $inputItem.Name } else { $inputItem.BaseName }
$timestamp = Get-Date -Format "HHmm"

if ([string]::IsNullOrWhiteSpace($ReportCsv)) {
    $reportDir = if ($inputItem.PSIsContainer) { $inputItem.FullName } else { $inputItem.Directory.FullName }
    $ReportCsv = Join-Path $reportDir ("{0}_{1}.csv" -f $reportBaseName, $timestamp)
}
else {
    $reportDir = Split-Path -Parent $ReportCsv
    if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
        New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "Purga anime audio"
Write-Host "Entrada       : $InputPath"
Write-Host "Salida        : misma carpeta de origen"
Write-Host "Modo          : $(if ($Execute) { 'EJECUCION REAL' } else { 'DRY RUN' })"
Write-Host "Total archivos: $($files.Count)"
Write-Host "============================================"
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$current = 0

foreach ($file in $files) {
    $current++
    Write-Host ("[{0}/{1}] Analizando: {2}" -f $current, $files.Count, $file.FullName)

    try {
        $json = & $mkvmergeCmd -J $file.FullName 2>$null
        if (-not $json) {
            throw "mkvmerge no devolvió datos JSON"
        }

        $data = $json | ConvertFrom-Json
        $audioTracks = @($data.tracks | Where-Object { $_.type -eq "audio" })

        $audioInfo = foreach ($track in $audioTracks) {
            $trackName = ""
            $language = ""

            if ($track.properties) {
                if ($track.properties.PSObject.Properties.Name -contains "track_name") {
                    $trackName = [string]$track.properties.track_name
                }
                if ($track.properties.PSObject.Properties.Name -contains "language") {
                    $language = [string]$track.properties.language
                }
            }

            $isJapanese  = Test-IsJapanese -Language $language -TrackName $trackName
            $isLatino    = Test-IsLatino   -Language $language -TrackName $trackName
            $isCastilian = Test-IsCastilian -Language $language -TrackName $trackName
            $isEnglish   = Test-IsEnglish  -Language $language -TrackName $trackName

            $defaultTrack = $false
            if ($track.properties -and $track.properties.PSObject.Properties.Name -contains "default_track") {
                $defaultTrack = [bool]$track.properties.default_track
            }

            [PSCustomObject]@{
                Id          = [int]$track.id
                Language    = $language
                TrackName   = $trackName
                IsJapanese  = $isJapanese
                IsLatino    = $isLatino
                IsCastilian = $isCastilian
                IsEnglish   = $isEnglish
                IsDefault   = $defaultTrack
            }
        }

        $japaneseTracks = @($audioInfo | Where-Object { $_.IsJapanese })
        $latinoTracks   = @($audioInfo | Where-Object { $_.IsLatino })

        $status = "OK"
        $notes = New-Object System.Collections.Generic.List[string]

        if ($japaneseTracks.Count -eq 0) {
            $status = "SKIP"
            $notes.Add("No se detectó audio japonés")
        }

        if ($latinoTracks.Count -eq 0) {
            $status = "SKIP"
            $notes.Add("No se detectó audio latino")
        }

        $selectedJapanese = $null
        if ($japaneseTracks.Count -gt 0) {
            $selectedJapanese = $japaneseTracks |
                Sort-Object @{ Expression = "IsDefault"; Descending = $true }, Id |
                Select-Object -First 1

            if ($japaneseTracks.Count -gt 1) {
                $notes.Add("Hay múltiples audios japoneses; se conservará el primero/default")
            }
        }

        $keepAudio = New-Object System.Collections.Generic.List[object]
        if ($selectedJapanese) {
            $keepAudio.Add($selectedJapanese)
        }

        foreach ($lat in ($latinoTracks | Sort-Object Id)) {
            $keepAudio.Add($lat)
        }

        $keepAudioIds = @($keepAudio | Select-Object -ExpandProperty Id)
        $dropAudio    = @($audioInfo | Where-Object { $_.Id -notin $keepAudioIds })

        $keepAudioText = @(
            $keepAudio | ForEach-Object {
                "[id=$($_.Id)] lang=$($_.Language) title=$($_.TrackName)"
            }
        ) -join " || "

        $dropAudioText = @(
            $dropAudio | ForEach-Object {
                "[id=$($_.Id)] lang=$($_.Language) title=$($_.TrackName)"
            }
        ) -join " || "

        $outputPath = Join-Path $file.Directory.FullName (Get-OutputName -OriginalName $file.Name)

        $result = [PSCustomObject]@{
            Archivo              = $file.Name
            Ruta                 = $file.FullName
            Estado               = $status
            Japones_Conservado   = if ($selectedJapanese) { "[id=$($selectedJapanese.Id)] $($selectedJapanese.TrackName)" } else { "" }
            Latinos_Conservados  = @($latinoTracks | Sort-Object Id | ForEach-Object { "[id=$($_.Id)] $($_.TrackName)" }) -join " || "
            Audios_Eliminados    = $dropAudioText
            Audios_Conservados   = $keepAudioText
            Salida               = $outputPath
            Notas                = ($notes -join " || ")
        }

        $results.Add($result)

        if ($status -ne "OK") {
            Write-Host "          Estado    : SKIP"
            Write-Host "          Motivo    : $($result.Notas)"
            continue
        }

        Write-Host "          Estado    : OK"
        Write-Host "          Conservar : $keepAudioText"
        Write-Host "          Eliminar  : $dropAudioText"
        Write-Host "          Salida    : $outputPath"

        if (-not $Execute) {
            continue
        }

        if ((Test-Path $outputPath) -and (-not $Overwrite)) {
            Write-Warning "El archivo ya existe y no se usó -Overwrite: $outputPath"
            continue
        }

        $audioTrackList = ($keepAudioIds | Sort-Object | ForEach-Object { $_.ToString() }) -join ","

        $args = @()
        $args += "-o"
        $args += $outputPath
        $args += "--audio-tracks"
        $args += $audioTrackList

        if ($selectedJapanese) {
            $args += "--default-track-flag"
            $args += "$($selectedJapanese.Id):yes"
        }

        foreach ($lat in ($latinoTracks | Sort-Object Id)) {
            $args += "--default-track-flag"
            $args += "$($lat.Id):no"
        }

        $args += $file.FullName

        if ($Overwrite -and (Test-Path $outputPath)) {
            Remove-Item -LiteralPath $outputPath -Force
        }

        & $mkvmergeCmd @args

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Falló el remux de: $($file.FullName)"
        }
    }
    catch {
        $errorResult = [PSCustomObject]@{
            Archivo              = $file.Name
            Ruta                 = $file.FullName
            Estado               = "ERROR"
            Japones_Conservado   = ""
            Latinos_Conservados  = ""
            Audios_Eliminados    = ""
            Audios_Conservados   = ""
            Salida               = ""
            Notas                = $_.Exception.Message
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