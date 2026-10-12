@echo off
rem Cold-start the FLang compiler from the committed seed C. See ..\README.md.
rem Uses cl from PATH, else the latest Visual Studio found by vswhere.
rem /experimental:c11atomics: stdlib atomic.c includes <stdatomic.h>.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
where cl >nul 2>nul || for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -property installationPath`) do call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d "%~dp0"
cl /nologo /W3 /std:c11 /experimental:c11atomics /O2 /Fe:flang-seed.exe *.c /link /INCREMENTAL:NO
