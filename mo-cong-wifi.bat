@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
netsh advfirewall firewall delete rule name="YouTube Personal iPhone 8899" >nul 2>&1
netsh advfirewall firewall add rule name="YouTube Personal iPhone 8899" dir=in action=allow protocol=TCP localport=8899 profile=any
echo Da mo cong LAN 8899 cho iPhone truy cap truc tiep toc do cao!
pause
