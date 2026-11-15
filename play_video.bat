@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
if exist "D:\TianLePlayer\_sdk\ffmpeg-master-latest-win64-lgpl-shared\bin\ffmpeg.exe" set FFMPEG=D:\TianLePlayer\_sdk\ffmpeg-master-latest-win64-lgpl-shared\bin\ffmpeg.exe
if not "%~1"=="" (set FILE=%~1) else (set FILE=%~dp0sample.mp4)
echo Sending: %FILE%
"C:\Users\65651\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" "%~dp0sender.py" --file "%FILE%" --loop
echo [stopped]
pause