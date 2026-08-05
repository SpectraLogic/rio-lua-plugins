@echo off
rem Usage: runme.bat <script> <input> [output]
if "%~2"=="" (
    echo Usage: %~nx0 ^<script^> ^<input^> [output]
    exit /b 1
)

where java >nul 2>&1
if errorlevel 1 (
    echo Error: java not found in PATH
    exit /b 1
)

set SCRIPT=%~1
set INPUT=%~2
set OUTPUT=%~3
if "%OUTPUT%"=="" set OUTPUT=%USERPROFILE%\proxy\lua-output

if not exist "%OUTPUT%" mkdir "%OUTPUT%"

java -DluaInput="%INPUT%" -DluaOutput="%OUTPUT%" ^
     -jar "plugin_test_harness-all.jar" "%SCRIPT%"
