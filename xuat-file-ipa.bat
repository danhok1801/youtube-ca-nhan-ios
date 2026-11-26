@echo off
chcp 65001 >nul
title Tu Dong Xuat File YouTubeCaNhan.ipa Cho iPhone
cd /d "%~dp0"
python build_ipa.py
pause
