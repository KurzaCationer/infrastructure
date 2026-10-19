@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Configuration: edit defaults here, or override with environment variables.
rem Names and defaults match check-cluster.sh. Blank backend values use GitHub.
if not defined REPOSITORY set "REPOSITORY=KurzaCationer/infrastructure"
if not defined CLUSTER_DIR set "CLUSTER_DIR=%~dp0..\terraform\cluster"
rem Set TF_STATE_BUCKET and AWS_REGION here to bypass GitHub variable lookup.
if not defined TF_STATE_BUCKET set "TF_STATE_BUCKET="
if not defined AWS_REGION set "AWS_REGION="
if not defined KUBECONFIG_PATH set "KUBECONFIG_PATH=%USERPROFILE%\.kube\kurza-infrastructure.yaml"
if not defined SYSTEM_NAMESPACE set "SYSTEM_NAMESPACE=kube-system"
if not defined GATEWAY_CLASS set "GATEWAY_CLASS=cilium"
if not defined REQUEST_TIMEOUT set "REQUEST_TIMEOUT=30s"
if not defined ROLLOUT_TIMEOUT set "ROLLOUT_TIMEOUT=120s"

rem Prerequisites and backend settings.

for %%T in (terraform tailscale kubectl) do (
  where %%T >nul 2>nul
  if errorlevel 1 (
    echo Required command not found: %%T 1>&2
    exit /b 1
  )
)
if not defined TF_STATE_BUCKET call :read_variable TF_STATE_BUCKET
if errorlevel 1 exit /b 1
if not defined AWS_REGION call :read_variable AWS_REGION
if errorlevel 1 exit /b 1

echo Reading the shared Terraform state using your existing AWS credentials...
terraform -chdir="%CLUSTER_DIR%" init -reconfigure -input=false "-backend-config=bucket=%TF_STATE_BUCKET%" "-backend-config=region=%AWS_REGION%"
if errorlevel 1 exit /b 1
terraform -chdir="%CLUSTER_DIR%" state list
if errorlevel 1 exit /b 1

for %%F in ("%KUBECONFIG_PATH%") do set "KUBECONFIG_DIR=%%~dpF"
if not exist "%KUBECONFIG_DIR%" mkdir "%KUBECONFIG_DIR%"
if errorlevel 1 exit /b 1
set "KUBECONFIG_TMP=%KUBECONFIG_PATH%.%RANDOM%.tmp"
terraform -chdir="%CLUSTER_DIR%" output -raw control_plane_hostname > "%KUBECONFIG_TMP%"
if errorlevel 1 goto :failed
set "CONTROL_PLANE_HOST="
set /p CONTROL_PLANE_HOST=<"%KUBECONFIG_TMP%"
if not defined CONTROL_PLANE_HOST (
  echo No control-plane hostname found in state. 1>&2
  goto :failed
)

rem Native redirection preserves Terraform's UTF-8 output without printing credentials.
terraform -chdir="%CLUSTER_DIR%" output -raw kubeconfig > "%KUBECONFIG_TMP%"
if errorlevel 1 goto :failed
for %%F in ("%KUBECONFIG_TMP%") do if %%~zF EQU 0 goto :failed
move /y "%KUBECONFIG_TMP%" "%KUBECONFIG_PATH%" >nul
if errorlevel 1 goto :failed

echo Kubeconfig saved to %KUBECONFIG_PATH%
echo Private node: %CONTROL_PLANE_HOST%
tailscale status
if errorlevel 1 exit /b 1
tailscale ping "%CONTROL_PLANE_HOST%"
if errorlevel 1 exit /b 1

kubectl --kubeconfig="%KUBECONFIG_PATH%" --request-timeout="%REQUEST_TIMEOUT%" cluster-info
if errorlevel 1 exit /b 1
kubectl --kubeconfig="%KUBECONFIG_PATH%" --request-timeout="%REQUEST_TIMEOUT%" get nodes -o wide
if errorlevel 1 exit /b 1
kubectl --kubeconfig="%KUBECONFIG_PATH%" --request-timeout="%REQUEST_TIMEOUT%" get pods -A
if errorlevel 1 exit /b 1
kubectl --kubeconfig="%KUBECONFIG_PATH%" -n "%SYSTEM_NAMESPACE%" rollout status daemonset/cilium --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
kubectl --kubeconfig="%KUBECONFIG_PATH%" -n "%SYSTEM_NAMESPACE%" rollout status deployment/cilium-operator --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
kubectl --kubeconfig="%KUBECONFIG_PATH%" --request-timeout="%REQUEST_TIMEOUT%" get gatewayclass "%GATEWAY_CLASS%"
if errorlevel 1 exit /b 1

echo.
echo Checks completed. For subsequent kubectl commands in this CMD session, run:
echo set "KUBECONFIG=%KUBECONFIG_PATH%"
echo For SSH, use your deployment private key with: ssh root@%CONTROL_PLANE_HOST%
exit /b 0

:read_variable
where gh >nul 2>nul
if errorlevel 1 (
  echo Install/authenticate gh, or set both TF_STATE_BUCKET and AWS_REGION. 1>&2
  exit /b 1
)
for /f "delims=" %%V in ('gh variable get %1 --repo "%REPOSITORY%" --json value --jq .value') do set "%1=%%V"
if not defined %1 (
  echo Could not read repository variable %1. 1>&2
  exit /b 1
)
exit /b 0

:failed
if exist "%KUBECONFIG_TMP%" del /q "%KUBECONFIG_TMP%"
echo Could not read a valid kubeconfig from state. Existing kubeconfig was preserved. 1>&2
exit /b 1
