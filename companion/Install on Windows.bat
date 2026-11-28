@echo off
rem Installs or updates the Un-Ninja Bank Discord companion. Needs Python 3.8+ from https://www.python.org/downloads/
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 install.py %*
) else (
  where python >nul 2>nul
  if errorlevel 1 (
    echo Python isn't installed. Get it from https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^), then run this again.
  ) else (
    python install.py %*
  )
)
pause
