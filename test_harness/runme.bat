@echo off
rem Usage: runme.bat <script> <input> [settings-json] [clip-dir] [output]
rem Can be run from any directory. Script, input, settings, clip and output paths are
rem resolved relative to the current directory; a bare input name not found
rem there falls back to .\source-input\<input>.
rem clip-dir (OP-Atom only) is the folder of essence files for the object.
setlocal
if "%~2"=="" (
    echo Usage: %~nx0 ^<script^> ^<input^> [settings-json] [clip-dir] [output]
    exit /b 1
)

where java >nul 2>&1
if errorlevel 1 (
    echo Error: java not found in PATH
    exit /b 1
)

set JAR_NAME=plugin_test_harness-all.jar
set HERE=%~dp0
if exist "%HERE%%JAR_NAME%" (
    set JAR=%HERE%%JAR_NAME%
) else if exist "%HERE%build\libs\%JAR_NAME%" (
    set JAR=%HERE%build\libs\%JAR_NAME%
) else (
    echo Error: %JAR_NAME% not found in %HERE% or %HERE%build\libs
    exit /b 1
)

set OPTS=-DluaInput="%~2"
if not "%~3"=="" set OPTS=%OPTS% -DluaSettings="%~3"
if not "%~4"=="" set OPTS=%OPTS% -DluaClip="%~4"
if not "%~5"=="" set OPTS=%OPTS% -DluaOutput="%~5"

java %OPTS% -jar "%JAR%" "%~1"
