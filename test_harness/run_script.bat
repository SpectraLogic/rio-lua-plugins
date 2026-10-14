@echo off
rem Test environment and required tools for Media Insight processing
setlocal

rem Always run from this script's own folder, so scripts\, settings.json and the
rem ..\ test files are found no matter where the user launched it from.
cd /d "%~dp0"

if /i "%~1"=="check" (
    echo Checking all tools
    call :check_tools ffmpeg ffprobe magick whisper-cli gswin64c aws
) else if /i "%~1"=="image_ollama" (
    echo image_ollama.lua
    call :check_tools magick && call runme.bat scripts\image_ollama.lua ..\Spectra-Cube.jpg settings.json
) else if /i "%~1"=="image_aws" (
    echo image_aws.lua
    call :check_tools magick aws && call runme.bat scripts\image_aws.lua ..\Spectra-Cube.jpg settings.json
) else if /i "%~1"=="pdf" (
    echo pdf.lua
    call :check_tools gswin64c magick && call runme.bat scripts\pdf.lua ..\lto9_tape_technology.pdf settings.json
) else if /i "%~1"=="audio_ollama" (
    echo audio_ollama.lua
    call :check_tools ffmpeg magick whisper-cli && call runme.bat scripts\audio_ollama.lua "..\University of Utah Backup Strategy.mp3" settings.json
) else if /i "%~1"=="audio_aws" (
    echo audio_aws.lua
    call :check_tools ffmpeg magick aws && call runme.bat scripts\audio_aws.lua "..\University of Utah Backup Strategy.mp3" settings.json
) else if /i "%~1"=="video_ollama" (
    echo video_ollama.lua
    call :check_tools ffmpeg ffprobe magick whisper-cli && call runme.bat scripts\video_ollama.lua "..\Introducing Rio Media Suite for Media Management & Archiving.mp4" settings.json
) else if /i "%~1"=="video_aws" (
    echo video_aws.lua
    call :check_tools ffmpeg ffprobe magick aws && call runme.bat scripts\video_aws.lua "..\Introducing Rio Media Suite for Media Management & Archiving.mp4" settings.json
) else if /i "%~1"=="opatom_aws" (
    echo opatom_aws.lua
    call :check_tools ffmpeg ffprobe magick aws && call runme.bat scripts\opatom_aws.lua "SVG HZS Interview" settings.json ..\HZS
) else if /i "%~1"=="opatom_ollama" (
    echo opatom_ollama.lua
    call :check_tools ffmpeg ffprobe magick whisper-cli && call runme.bat scripts\opatom_ollama.lua "SVG HZS Interview" settings.json ..\HZS
) else (
    echo Usage: %~nx0 {check^|image_ollama^|image_aws^|pdf^|audio_ollama^|audio_aws^|video_ollama^|video_aws^|opatom_aws^|opatom_ollama}
    exit /b 1
)
exit /b %errorlevel%

rem check_tools tool...  -- prints OK/FAIL for each tool; returns 1 if any are missing.
:check_tools
set _FAILED=0
:check_tools_loop
if "%~1"=="" exit /b %_FAILED%
set "_NAME=%~1            "
set "_NAME=%_NAME:~0,12%"
set _PATH=
for /f "delims=" %%p in ('where %~1 2^>nul') do if not defined _PATH set "_PATH=%%p"
if not defined _PATH goto :check_tools_fail
echo OK    %_NAME% %_PATH%
goto :check_tools_next
:check_tools_fail
echo FAIL  %_NAME% not found in PATH
set _FAILED=1
:check_tools_next
shift
goto :check_tools_loop
