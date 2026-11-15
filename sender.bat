@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
if exist "D:\TianLePlayer\_sdk\ffmpeg-master-latest-win64-lgpl-shared\bin\ffmpeg.exe" set FFMPEG=D:\TianLePlayer\_sdk\ffmpeg-master-latest-win64-lgpl-shared\bin\ffmpeg.exe
if "%~1"=="" goto usage
"C:\Users\65651\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" "%~dp0sender.py" %*
goto end
:usage
echo.
echo   sender.bat --file "D:\video.mp4" --host 192.168.10.2 --loop
echo   sender.bat --file "D:\video.mp4" --host 192.168.10.2 --loop --audio --audio-device "Stereo Mix"
echo   sender.bat --list
echo.
pause
:end