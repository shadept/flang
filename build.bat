@echo off
setlocal ENABLEDELAYEDEXECUTION

REM Simple build script for FLang — produces Release artifacts and fills ./dist as configured
REM Usage:
REM   build.bat [RID]
REM Examples:
REM   build.bat            -> builds for default RID (win-x64)
REM   build.bat win-x64    -> builds Windows x64
REM   build.bat linux-x64  -> builds Linux x64 (on a machine/CI that can cross-publish)

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%" >NUL

set "RID=%~1"
if "%RID%"=="" set "RID=win-x64"

echo === Building FLang.CLI (Release) for RID=%RID% ===
echo.

REM Restore solution packages (optional but explicit)
dotnet restore "flang.sln"
if errorlevel 1 goto :build_failed

REM Publish FLang.CLI; the .csproj is already configured to produce a single-file, self-contained exe
REM and copy the final artifact to ./dist/<RID>/flang.exe along with ./dist/<RID>/stdlib/**
dotnet publish "src\FLang.CLI\FLang.CLI.csproj" -c Release -r %RID% -nologo
if errorlevel 1 goto :build_failed

set "DIST_DIR=dist\%RID%"
set "FINAL_EXE=%DIST_DIR%\flang.exe"

echo.
if exist "%FINAL_EXE%" (
  for %%I in ("%FINAL_EXE%") do set "FILE_SIZE=%%~zI"
  echo Success: %FINAL_EXE% (%%FILE_SIZE%% bytes)
  if exist "%DIST_DIR%\stdlib" (
    echo Stdlib copied to: %DIST_DIR%\stdlib\
  ) else (
    echo Note: stdlib folder not found at %DIST_DIR%\stdlib\
  )
  echo.
  echo Done.
  popd >NUL
  endlocal & exit /b 0
) else (
  echo Warning: Expected final artifact was not found at %FINAL_EXE%
  echo The publish may have succeeded, but the post-publish copy step might have been skipped.
  echo Check the publish logs and the MSBuild target in src\FLang.CLI\FLang.CLI.csproj.
  popd >NUL
  endlocal & exit /b 1
)

:build_failed
echo.
echo Build failed. See errors above.
popd >NUL
endlocal & exit /b 1
