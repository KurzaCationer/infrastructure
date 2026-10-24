@echo off
setlocal EnableExtensions DisableDelayedExpansion

if not defined REPOSITORY set "REPOSITORY=KurzaCationer/infrastructure"
if not defined CLUSTER_DIR set "CLUSTER_DIR=%~dp0..\terraform\cluster"
if not defined KUBECONFIG_PATH set "KUBECONFIG_PATH=%USERPROFILE%\.kube\kurza-infrastructure.yaml"

for %%T in (terraform kubectl) do (
  where %%T >nul 2>nul
  if errorlevel 1 (
    echo Required command not found: %%T 1>&2
    exit /b 1
  )
)
for %%F in ("%KUBECONFIG_PATH%") do set "KUBECONFIG_DIR=%%~dpF"
if not exist "%KUBECONFIG_DIR%" mkdir "%KUBECONFIG_DIR%"
if errorlevel 1 exit /b 1
set "WORK_DIR=%KUBECONFIG_PATH%.%RANDOM%.%RANDOM%.tmp"
if exist "%WORK_DIR%" exit /b 1
mkdir "%WORK_DIR%"
if errorlevel 1 exit /b 1

if not defined TF_STATE_BUCKET call :read_variable TF_STATE_BUCKET
if errorlevel 1 goto :failed
if not defined AWS_REGION call :read_variable AWS_REGION
if errorlevel 1 goto :failed

call terraform -chdir="%CLUSTER_DIR%" init -reconfigure -input=false "-backend-config=bucket=%TF_STATE_BUCKET%" "-backend-config=region=%AWS_REGION%"
if errorlevel 1 goto :failed
call terraform -chdir="%CLUSTER_DIR%" output -raw kubeconfig > "%WORK_DIR%\config"
if errorlevel 1 goto :failed
for %%F in ("%WORK_DIR%\config") do if %%~zF EQU 0 goto :failed
call kubectl --kubeconfig="%WORK_DIR%\config" config view --minify -o "jsonpath={.clusters[0].cluster.server}" > "%WORK_DIR%\server"
if errorlevel 1 goto :failed
set "API_SERVER="
set /p API_SERVER=<"%WORK_DIR%\server"
if not defined API_SERVER goto :failed
move /y "%WORK_DIR%\config" "%KUBECONFIG_PATH%" >nul
if errorlevel 1 goto :failed
call :cleanup

echo Kubeconfig saved to %KUBECONFIG_PATH%
echo API server: %API_SERVER%
echo set "KUBECONFIG=%KUBECONFIG_PATH%"
exit /b 0

:read_variable
where gh >nul 2>nul
if errorlevel 1 (
  echo Install/authenticate gh, or set both TF_STATE_BUCKET and AWS_REGION. 1>&2
  exit /b 1
)
call gh variable get %1 --repo "%REPOSITORY%" --json value --jq .value > "%WORK_DIR%\variable"
if errorlevel 1 exit /b 1
set /p %1=<"%WORK_DIR%\variable"
if not defined %1 (
  echo Could not read repository variable %1. 1>&2
  exit /b 1
)
exit /b 0

:cleanup
for %%F in (config server variable) do if exist "%WORK_DIR%\%%F" del /q "%WORK_DIR%\%%F"
rmdir "%WORK_DIR%"
exit /b 0

:failed
call :cleanup
echo Could not retrieve kubeconfig. Existing kubeconfig was preserved. 1>&2
exit /b 1
