@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================
REM BASE
REM ============================================================
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "SCRIPT_PURGE=%SCRIPT_DIR%\purge-mkv.ps1"
set "SCRIPT_AUDIO=%SCRIPT_DIR%\audio-to-aac.ps1"
set "SCRIPT_VIDEO=%SCRIPT_DIR%\video-to-x264.ps1"

set "PSCMD=powershell -NoProfile -ExecutionPolicy Bypass"

REM Flags por defecto
set "USE_RECURSE=1"
set "USE_OVERWRITE=0"
set "VIDEO_1080P=0"

REM ============================================================
REM TARGET_DIR: por argumento o por prompt
REM ============================================================
if not "%~1"=="" (
    set "TARGET_DIR=%~1"
) else (
    set /p "TARGET_DIR=Escribe la carpeta objetivo: "
)

if "%TARGET_DIR%"=="" (
    echo No se especifico carpeta objetivo.
    pause
    exit /b 1
)

set "TARGET_DIR=%TARGET_DIR:"=%"

if not exist "%TARGET_DIR%" (
    echo No existe la carpeta objetivo:
    echo %TARGET_DIR%
    pause
    exit /b 1
)

REM ============================================================
REM VALIDAR SCRIPTS
REM ============================================================
call :check_file "%SCRIPT_PURGE%" "purge-mkv.ps1"
if errorlevel 1 exit /b 1

call :check_file "%SCRIPT_AUDIO%" "audio-to-aac.ps1"
if errorlevel 1 exit /b 1

call :check_file "%SCRIPT_VIDEO%" "video-to-x264.ps1"
if errorlevel 1 exit /b 1

REM ============================================================
REM RESOLVER HERRAMIENTAS (portable / relativas / PATH)
REM ============================================================
call :resolve_mkvmerge
if errorlevel 1 exit /b 1

call :resolve_ffmpeg
if errorlevel 1 exit /b 1

call :resolve_ffprobe
if errorlevel 1 exit /b 1

goto :menu

REM ============================================================
REM MENU
REM ============================================================
:menu
cls
echo ============================================
echo MKV PIPELINE FINAL
echo ============================================
echo Carpeta objetivo : %TARGET_DIR%
echo Script dir       : %SCRIPT_DIR%
echo.
echo MKVMERGE         : %MKVMERGE%
echo FFMPEG           : %FFMPEG%
echo FFPROBE          : %FFPROBE%
echo.
echo Recurse          : %USE_RECURSE%
echo Overwrite        : %USE_OVERWRITE%
echo Video 1080p      : %VIDEO_1080P%
echo.
echo 1^) Pipeline completo guiado ^(dry + exec^)
echo 2^) Pipeline rapido secuencial ^(exec only^)
echo 3^) Solo purga
echo 4^) Solo audio desde _  a __
echo 5^) Solo video desde __ a ___
echo 6^) Solo optimizacion secuencial desde originales ^(audio y luego video^)
echo 7^) Cambiar carpeta objetivo
echo 8^) Toggle Recurse
echo 9^) Toggle Overwrite
echo 10^) Toggle Video 1080p
echo 11^) Re-detectar herramientas
echo 0^) Salir
echo.
set /p "CHOICE=Selecciona una opcion: "

if "%CHOICE%"=="1" goto :pipeline_guided
if "%CHOICE%"=="2" goto :pipeline_fast
if "%CHOICE%"=="3" goto :purge_only
if "%CHOICE%"=="4" goto :audio_only
if "%CHOICE%"=="5" goto :video_only
if "%CHOICE%"=="6" goto :optimize_from_originals
if "%CHOICE%"=="7" goto :change_target
if "%CHOICE%"=="8" goto :toggle_recurse
if "%CHOICE%"=="9" goto :toggle_overwrite
if "%CHOICE%"=="10" goto :toggle_video1080
if "%CHOICE%"=="11" goto :redetect_tools
if "%CHOICE%"=="0" goto :eof

echo Opcion invalida.
pause
goto :menu

REM ============================================================
REM TOGGLES / CONFIG
REM ============================================================
:toggle_recurse
if "%USE_RECURSE%"=="1" (
    set "USE_RECURSE=0"
) else (
    set "USE_RECURSE=1"
)
goto :menu

:toggle_overwrite
if "%USE_OVERWRITE%"=="1" (
    set "USE_OVERWRITE=0"
) else (
    set "USE_OVERWRITE=1"
)
goto :menu

:toggle_video1080
if "%VIDEO_1080P%"=="1" (
    set "VIDEO_1080P=0"
) else (
    set "VIDEO_1080P=1"
)
goto :menu

:change_target
set /p "NEWTARGET=Nueva carpeta objetivo: "
if not "%NEWTARGET%"=="" (
    set "NEWTARGET=%NEWTARGET:"=%"
    if exist "%NEWTARGET%" (
        set "TARGET_DIR=%NEWTARGET%"
    ) else (
        echo La carpeta no existe.
        pause
    )
)
goto :menu

:redetect_tools
call :resolve_mkvmerge
if errorlevel 1 exit /b 1
call :resolve_ffmpeg
if errorlevel 1 exit /b 1
call :resolve_ffprobe
if errorlevel 1 exit /b 1
echo.
echo Herramientas detectadas nuevamente.
pause
goto :menu

REM ============================================================
REM PIPELINES
REM ============================================================
:pipeline_guided
cls
echo ============================================
echo PIPELINE COMPLETO GUIADO
echo ============================================
echo Original ^> _ ^> __ ^> ___
echo.
pause

call :run_purge_dry
if errorlevel 1 goto :stage_fail
pause

call :run_purge_exec
if errorlevel 1 goto :stage_fail
pause

call :run_audio_dry_from_purged
if errorlevel 1 goto :stage_fail
pause

call :run_audio_exec_from_purged
if errorlevel 1 goto :stage_fail
pause

call :run_video_dry_from_double
if errorlevel 1 goto :stage_fail
pause

call :run_video_exec_from_double
if errorlevel 1 goto :stage_fail
pause

echo.
echo ============================================
echo PIPELINE COMPLETADO
echo Archivo final esperado: ___nombre.mkv
echo ============================================
pause
goto :menu

:pipeline_fast
cls
echo ============================================
echo PIPELINE RAPIDO SECUENCIAL
echo ============================================
echo Original ^> _ ^> __ ^> ___
echo.
pause

call :run_purge_exec
if errorlevel 1 goto :stage_fail_fast

call :run_audio_exec_from_purged
if errorlevel 1 goto :stage_fail_fast

call :run_video_exec_from_double
if errorlevel 1 goto :stage_fail_fast

echo.
echo ============================================
echo PIPELINE RAPIDO COMPLETADO
echo Archivo final esperado: ___nombre.mkv
echo ============================================
pause
goto :menu

:stage_fail_fast
echo.
echo ============================================
echo EL PIPELINE RAPIDO SE DETUVO POR ERROR
echo ============================================
pause
goto :menu

:stage_fail
echo.
echo ============================================
echo EL PIPELINE SE DETUVO POR ERROR
echo ============================================
pause
goto :menu

REM ============================================================
REM ACTIONS
REM ============================================================
:purge_only
call :run_purge_exec
pause
goto :menu

:audio_only
call :run_audio_exec_from_purged
pause
goto :menu

:video_only
call :run_video_exec_from_double
pause
goto :menu

:optimize_from_originals
cls
echo ============================================
echo OPTIMIZACION SECUENCIAL DESDE ORIGINALES
echo ============================================
echo Original ^> __ ^> ___
echo.
echo Esto NO hace purga.
echo Primero audio desde original, luego video sobre __
echo.
pause

call :run_audio_exec_from_originals
if errorlevel 1 goto :stage_fail_opt

call :run_video_exec_from_double
if errorlevel 1 goto :stage_fail_opt

echo.
echo ============================================
echo OPTIMIZACION COMPLETADA
echo Archivo final esperado: ___nombre.mkv
echo ============================================
pause
goto :menu

:stage_fail_opt
echo.
echo ============================================
echo LA OPTIMIZACION SE DETUVO POR ERROR
echo ============================================
pause
goto :menu

REM ============================================================
REM RUNNERS
REM ============================================================
:run_purge_dry
echo.
echo [PURGA] Dry run...
set "ARGS=-InputPath "%TARGET_DIR%" -MkvmergePath "%MKVMERGE%""
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
%PSCMD% -File "%SCRIPT_PURGE%" !ARGS!
exit /b %errorlevel%

:run_purge_exec
echo.
echo [PURGA] Ejecucion real...
set "ARGS=-InputPath "%TARGET_DIR%" -MkvmergePath "%MKVMERGE%" -Execute"
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
if "%USE_OVERWRITE%"=="1" set "ARGS=!ARGS! -Overwrite"
%PSCMD% -File "%SCRIPT_PURGE%" !ARGS!
exit /b %errorlevel%

:run_audio_dry_from_purged
echo.
echo [AUDIO] Dry run FLAC ^> AAC desde _ hacia __ ...
set "ARGS=-InputPath "%TARGET_DIR%" -FfmpegPath "%FFMPEG%" -FfprobePath "%FFPROBE%" -InputPrefix "_" -OutputPrefix "__""
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
%PSCMD% -File "%SCRIPT_AUDIO%" !ARGS!
exit /b %errorlevel%

:run_audio_exec_from_purged
echo.
echo [AUDIO] Ejecucion real FLAC ^> AAC desde _ hacia __ ...
set "ARGS=-InputPath "%TARGET_DIR%" -FfmpegPath "%FFMPEG%" -FfprobePath "%FFPROBE%" -InputPrefix "_" -OutputPrefix "__" -Execute"
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
if "%USE_OVERWRITE%"=="1" set "ARGS=!ARGS! -Overwrite"
%PSCMD% -File "%SCRIPT_AUDIO%" !ARGS!
exit /b %errorlevel%

:run_audio_exec_from_originals
echo.
echo [AUDIO] Ejecucion real FLAC ^> AAC desde originales hacia __ ...
set "ARGS=-InputPath "%TARGET_DIR%" -FfmpegPath "%FFMPEG%" -FfprobePath "%FFPROBE%" -InputPrefix "" -OutputPrefix "__" -Execute"
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
if "%USE_OVERWRITE%"=="1" set "ARGS=!ARGS! -Overwrite"
%PSCMD% -File "%SCRIPT_AUDIO%" !ARGS!
exit /b %errorlevel%

:run_video_dry_from_double
echo.
echo [VIDEO] Dry run HEVC ^> x264 desde __ hacia ___ ...
set "ARGS=-InputPath "%TARGET_DIR%" -FfmpegPath "%FFMPEG%" -FfprobePath "%FFPROBE%" -InputPrefix "__" -OutputPrefix "___""
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
if "%VIDEO_1080P%"=="1" set "ARGS=!ARGS! -Downscale1080p"
%PSCMD% -File "%SCRIPT_VIDEO%" !ARGS!
exit /b %errorlevel%

:run_video_exec_from_double
echo.
echo [VIDEO] Ejecucion real HEVC ^> x264 desde __ hacia ___ ...
set "ARGS=-InputPath "%TARGET_DIR%" -FfmpegPath "%FFMPEG%" -FfprobePath "%FFPROBE%" -InputPrefix "__" -OutputPrefix "___" -Execute"
if "%USE_RECURSE%"=="1" set "ARGS=!ARGS! -Recurse"
if "%USE_OVERWRITE%"=="1" set "ARGS=!ARGS! -Overwrite"
if "%VIDEO_1080P%"=="1" set "ARGS=!ARGS! -Downscale1080p"
%PSCMD% -File "%SCRIPT_VIDEO%" !ARGS!
exit /b %errorlevel%

REM ============================================================
REM TOOL RESOLUTION
REM ============================================================
:resolve_mkvmerge
set "MKVMERGE="

if exist "%SCRIPT_DIR%\mkvmerge.exe" set "MKVMERGE=%SCRIPT_DIR%\mkvmerge.exe"
if not defined MKVMERGE (
    for %%F in ("%SCRIPT_DIR%\mkvtoolnix\mkvmerge.exe") do if exist "%%~fF" set "MKVMERGE=%%~fF"
)
if not defined MKVMERGE (
    for %%F in ("%SCRIPT_DIR%\..\mkvtoolnix\mkvmerge.exe") do if exist "%%~fF" set "MKVMERGE=%%~fF"
)
if not defined MKVMERGE (
    for %%F in ("%SCRIPT_DIR%\..\mkvtoolnix-*\mkvtoolnix\mkvmerge.exe") do if exist "%%~fF" set "MKVMERGE=%%~fF"
)
if not defined MKVMERGE (
    for /f "delims=" %%F in ('where mkvmerge.exe 2^>nul') do (
        if not defined MKVMERGE set "MKVMERGE=%%F"
    )
)

if not defined MKVMERGE (
    echo No pude encontrar mkvmerge.exe
    echo Colocalo junto al BAT, en una carpeta relativa o en PATH.
    pause
    exit /b 1
)
exit /b 0

:resolve_ffmpeg
set "FFMPEG="

if exist "%SCRIPT_DIR%\ffmpeg.exe" set "FFMPEG=%SCRIPT_DIR%\ffmpeg.exe"
if not defined FFMPEG (
    for %%F in ("%SCRIPT_DIR%\ffmpeg\bin\ffmpeg.exe") do if exist "%%~fF" set "FFMPEG=%%~fF"
)
if not defined FFMPEG (
    for %%F in ("%SCRIPT_DIR%\..\ffmpeg\bin\ffmpeg.exe") do if exist "%%~fF" set "FFMPEG=%%~fF"
)
if not defined FFMPEG (
    for %%F in ("%SCRIPT_DIR%\..\ffmpeg-*\bin\ffmpeg.exe") do if exist "%%~fF" set "FFMPEG=%%~fF"
)
if not defined FFMPEG (
    for %%F in ("%SCRIPT_DIR%\..\..\ffmpeg\bin\ffmpeg.exe") do if exist "%%~fF" set "FFMPEG=%%~fF"
)
if not defined FFMPEG (
    for %%F in ("%SCRIPT_DIR%\..\..\ffmpeg-*\bin\ffmpeg.exe") do if exist "%%~fF" set "FFMPEG=%%~fF"
)
if not defined FFMPEG (
    for /f "delims=" %%F in ('where ffmpeg.exe 2^>nul') do (
        if not defined FFMPEG set "FFMPEG=%%F"
    )
)

if not defined FFMPEG (
    echo No pude encontrar ffmpeg.exe
    echo Colocalo junto al BAT, en una carpeta relativa o en PATH.
    pause
    exit /b 1
)
exit /b 0

:resolve_ffprobe
set "FFPROBE="

if exist "%SCRIPT_DIR%\ffprobe.exe" set "FFPROBE=%SCRIPT_DIR%\ffprobe.exe"
if not defined FFPROBE (
    for %%F in ("%SCRIPT_DIR%\ffmpeg\bin\ffprobe.exe") do if exist "%%~fF" set "FFPROBE=%%~fF"
)
if not defined FFPROBE (
    for %%F in ("%SCRIPT_DIR%\..\ffmpeg\bin\ffprobe.exe") do if exist "%%~fF" set "FFPROBE=%%~fF"
)
if not defined FFPROBE (
    for %%F in ("%SCRIPT_DIR%\..\ffmpeg-*\bin\ffprobe.exe") do if exist "%%~fF" set "FFPROBE=%%~fF"
)
if not defined FFPROBE (
    for %%F in ("%SCRIPT_DIR%\..\..\ffmpeg\bin\ffprobe.exe") do if exist "%%~fF" set "FFPROBE=%%~fF"
)
if not defined FFPROBE (
    for %%F in ("%SCRIPT_DIR%\..\..\ffmpeg-*\bin\ffprobe.exe") do if exist "%%~fF" set "FFPROBE=%%~fF"
)
if not defined FFPROBE (
    for /f "delims=" %%F in ('where ffprobe.exe 2^>nul') do (
        if not defined FFPROBE set "FFPROBE=%%F"
    )
)

if not defined FFPROBE (
    echo No pude encontrar ffprobe.exe
    echo Colocalo junto al BAT, en una carpeta relativa o en PATH.
    pause
    exit /b 1
)
exit /b 0

REM ============================================================
REM HELPERS
REM ============================================================
:check_file
if not exist "%~1" (
    echo Falta %~2:
    echo %~1
    pause
    exit /b 1
)
exit /b 0