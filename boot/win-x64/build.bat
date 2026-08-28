@echo off
rem Cold-start the FLang compiler from the committed seed C. See ..\README.md.
rem Needs cl on PATH (VS developer prompt, or vcvars64 run first).
rem /experimental:c11atomics: stdlib atomic.c includes <stdatomic.h>.
cl /nologo /W3 /std:c11 /experimental:c11atomics /O2 /Fe:flang-seed.exe *.c /link /INCREMENTAL:NO
