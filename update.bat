@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================
echo  地推工具 - 一键更新代码
echo ============================
echo.

if not exist .env (
    echo [警告] 当前目录没有 .env 文件
    echo 请确认这个 update.bat 在 E:\tuiguang\ 文件夹里
    echo 如果是第一次用，先运行 copy .env.example .env 再填key
    echo.
    pause
    exit /b 1
)

echo [1/5] 备份 .env 到 .env.bak（以防万一）...
copy /y .env .env.bak >nul

echo [2/5] 下载最新代码包...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri 'https://github.com/mahaitong4-droid/-1/archive/refs/heads/claude/elegant-allen-005kgx.zip' -OutFile '_update.zip' -UseBasicParsing } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo [错误] 下载失败，请检查网络
    pause
    exit /b 1
)

echo [3/5] 解压...
if exist _update rmdir /s /q _update
powershell -NoProfile -Command "Expand-Archive -Path '_update.zip' -DestinationPath '_update' -Force"

echo [4/5] 覆盖到当前目录（.env 不会动）...
for /d %%i in (_update\*) do (
    xcopy /e /y /q /i "%%i\*" . >nul
)

echo [5/5] 清理临时文件...
rmdir /s /q _update
del _update.zip

echo.
echo ============================
echo   完成 ✓  .env 文件已保留
echo ============================
echo.
echo 接下来在 cmd 里运行：
echo    python -m backend.main
echo.
pause
