@echo off
REM Double-click friendly launcher for install-firefox.ps1 on Windows.
REM Runs the PowerShell installer with a process-scoped execution-policy
REM bypass (does not change machine policy) and forwards any arguments.
REM
REM Usage:
REM   install-firefox.cmd            (defaults to "run")
REM   install-firefox.cmd build
REM   install-firefox.cmd sign
REM   install-firefox.cmd lint
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-firefox.ps1" %*
