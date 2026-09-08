@echo off
chcp 65001 >nul
cd /d "%~dp0"
setlocal enabledelayedexpansion

set VERSION=0.2.0
set BRANCH=claude/elegant-allen-005kgx

echo ==========================================
echo   地推商圈分析 - 一键更新到 v%VERSION%
echo ==========================================
echo.

if not exist .env (
    echo [提示] 当前目录没有 .env 文件
    echo 如果这是第一次用，更新完记得执行：
    echo     copy .env.example .env
    echo 然后按里面的说明填 key（默认方案只要 2 个免费 key）
    echo.
)

echo [1/6] 备份 .env 和你改过的词库...
if exist .env copy /y .env .env.bak >nul
if exist _backup rmdir /s /q _backup
mkdir _backup >nul 2>&1
for %%f in (chain_brands.txt labor_keywords.txt) do (
    if exist "data\%%f" copy /y "data\%%f" "_backup\%%f" >nul
)

echo [2/6] 下载最新代码包...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri 'https://github.com/mahaitong4-droid/-1/archive/refs/heads/%BRANCH%.zip' -OutFile '_update.zip' -UseBasicParsing } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo [错误] 下载失败，请检查网络
    pause
    exit /b 1
)

echo [3/6] 解压...
if exist _update rmdir /s /q _update
powershell -NoProfile -Command "Expand-Archive -Path '_update.zip' -DestinationPath '_update' -Force"
if errorlevel 1 (
    echo [错误] 解压失败
    pause
    exit /b 1
)

echo [4/6] 覆盖到当前目录（.env 不会动）...
for /d %%i in (_update\*) do (
    xcopy /e /y /q /i "%%i\*" . >nul
)

echo [5/6] 还原你改过的词库...
for %%f in (chain_brands.txt labor_keywords.txt) do (
    if exist "_backup\%%f" (
        fc /b "_backup\%%f" "data\%%f" >nul 2>&1
        if errorlevel 1 (
            move /y "data\%%f" "data\%%f.new" >nul
            copy /y "_backup\%%f" "data\%%f" >nul
            echo     * 你改过 %%f，已保留你的版本；官方新版另存为 data\%%f.new
        )
    )
)

echo [6/6] 清理临时文件和已废弃的旧模块...
rmdir /s /q _update
rmdir /s /q _backup
del _update.zip
rem v0.2.0 把这两个模块拆掉了（amap.py -> poi.py，deepseek.py -> llm.py），
rem xcopy 只会新增/覆盖不会删除，所以这里手动清掉，免得留着误导人
if exist backend\amap.py del /q backend\amap.py
if exist backend\deepseek.py del /q backend\deepseek.py
for /d /r backend %%d in (__pycache__) do @if exist "%%d" rmdir /s /q "%%d"

echo.
echo ==========================================
echo   更新完成 v%VERSION%   .env 已保留
echo ==========================================
echo.
echo 接下来双击 run.bat 就行 --
echo 它会自动装依赖、启动服务、打开浏览器。
echo.
echo （如果还没配 key，run.bat 会问你要，都是免费的；
echo   直接回车跳过也能跑，网页上会告诉你去哪申请）
echo.
pause
