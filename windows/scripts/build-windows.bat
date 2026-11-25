@echo off
REM Build the per-user QuotaBar NSIS installer on Windows.

cd /d "%~dp0\.."

echo Installing dependencies...
call bun install --frozen-lockfile
if errorlevel 1 exit /b 1

echo Building Tauri app...
for /f "tokens=2" %%T in ('rustc -vV ^| findstr /b /c:"host:"') do set "CARGO_BUILD_TARGET=%%T"
if not defined CARGO_BUILD_TARGET exit /b 1
call bun run tauri:build --bundles nsis --ci --target "%CARGO_BUILD_TARGET%" -- --locked
if errorlevel 1 exit /b 1

echo.
echo Build complete. Output:
dir /b "target\%CARGO_BUILD_TARGET%\release\bundle\nsis\*-setup.exe"
exit /b 0
