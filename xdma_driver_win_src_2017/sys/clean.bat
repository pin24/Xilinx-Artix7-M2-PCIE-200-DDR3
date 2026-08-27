@echo off
set SYS=%~dp0
set SYS=%SYS:~0,-1%
if exist "%SYS%\..\build\x64\XDMA_Driver" rmdir /s /q "%SYS%\..\build\x64\XDMA_Driver"
if exist "%SYS%\..\build_tmp\XDMA_Driver" rmdir /s /q "%SYS%\..\build_tmp\XDMA_Driver"
if exist "%SYS%\XDMA.sys" del /q "%SYS%\XDMA.sys"
echo CLEAN OK