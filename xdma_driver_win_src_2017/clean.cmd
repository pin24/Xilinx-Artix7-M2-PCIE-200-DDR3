@echo off
setlocal
set BASE=%~dp0
if exist "%BASE%build\sys" rmdir /s /q "%BASE%build\sys"
if exist "%BASE%build\exe" rmdir /s /q "%BASE%build\exe"
if exist "%BASE%build_tmp" rmdir /s /q "%BASE%build_tmp"
echo CLEAN OK