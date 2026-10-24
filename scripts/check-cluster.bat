@echo off
setlocal EnableExtensions DisableDelayedExpansion

if not defined KUBECONFIG_PATH set "KUBECONFIG_PATH=%USERPROFILE%\.kube\kurza-infrastructure.yaml"
if not defined SYSTEM_NAMESPACE set "SYSTEM_NAMESPACE=kube-system"
if not defined GATEWAY_CLASS set "GATEWAY_CLASS=cilium"
if not defined REQUEST_TIMEOUT set "REQUEST_TIMEOUT=30s"
if not defined ROLLOUT_TIMEOUT set "ROLLOUT_TIMEOUT=120s"

where kubectl >nul 2>nul
if errorlevel 1 (
  echo Required command not found: kubectl 1>&2
  exit /b 1
)
if not exist "%KUBECONFIG_PATH%" goto :retrieve
for %%F in ("%KUBECONFIG_PATH%") do if %%~zF EQU 0 goto :retrieve
goto :check

:retrieve
call "%~dp0get-kubeconfig.bat"
if errorlevel 1 exit /b 1

:check
echo Checking cluster using %KUBECONFIG_PATH%
call :kubectl cluster-info
if errorlevel 1 exit /b 1
call :kubectl get nodes -o wide
if errorlevel 1 exit /b 1
call :kubectl get pods -A
if errorlevel 1 exit /b 1
call :kubectl wait nodes --all --for=condition=Ready --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl rollout status -n "%SYSTEM_NAMESPACE%" daemonset/cilium --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl rollout status -n "%SYSTEM_NAMESPACE%" deployment/cilium-operator --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl wait gatewayclass "%GATEWAY_CLASS%" --for=condition=Accepted --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1

for %%N in (sm-operator-system tailscale argocd cert-manager external-dns cnpg-system pocket-id) do (
  call :kubectl wait deployment -n %%N --all --for=condition=Available --timeout="%ROLLOUT_TIMEOUT%"
  if errorlevel 1 exit /b 1
)
call :kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl get applications -n argocd
if errorlevel 1 exit /b 1
call :kubectl wait applications -n argocd --all --for=jsonpath="{.status.sync.status}"=Synced --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl wait applications -n argocd --all --for=jsonpath="{.status.health.status}"=Healthy --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl wait certificates -n public-ingress --all --for=condition=Ready --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl wait gateway/public -n public-ingress --for=condition=Programmed --timeout="%ROLLOUT_TIMEOUT%"
if errorlevel 1 exit /b 1
call :kubectl get ingress -n argocd
if errorlevel 1 exit /b 1
call :kubectl get httproutes -A
if errorlevel 1 exit /b 1

echo.
echo Cluster checks passed.
echo set "KUBECONFIG=%KUBECONFIG_PATH%"
exit /b 0

:kubectl
call kubectl --kubeconfig="%KUBECONFIG_PATH%" --request-timeout="%REQUEST_TIMEOUT%" %*
exit /b %errorlevel%
