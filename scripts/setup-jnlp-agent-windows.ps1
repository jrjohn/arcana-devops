# Set up Jenkins JNLP agent on Windows as a Windows service
# Connects outbound to https://arcana.boo/jenkins/ via WebSocket
#
# Prerequisites:
#   - Java 17+ installed and in PATH
#   - Run as Administrator
#
# Usage: .\setup-jnlp-agent-windows.ps1 -Secret <agent-secret>
#   Get the secret from: Jenkins -> Manage Jenkins -> Nodes -> windows

param(
    [Parameter(Mandatory=$true)]
    [string]$Secret
)

$JenkinsUrl = "https://arcana.boo/jenkins/"
$AgentName = "windows"
$AgentDir = "C:\jenkins-agent"
$AgentJar = "$AgentDir\agent.jar"
$ServiceName = "JenkinsAgent"

# ── Check admin ───────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# ── Check Java ────────────────────────────────
try {
    $null = & java -version 2>&1
} catch {
    Write-Error "Java not found. Install Java 17+: winget install Microsoft.OpenJDK.17"
    exit 1
}

# ── Setup directory ───────────────────────────
Write-Host "Setting up Jenkins JNLP agent..."
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

# ── Download agent.jar ────────────────────────
Write-Host "Downloading agent.jar..."
Invoke-WebRequest -Uri "${JenkinsUrl}jnlpJars/agent.jar" -OutFile $AgentJar

# ── Stop existing service ─────────────────────
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Stopping existing service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName 2>$null
    Start-Sleep -Seconds 2
}

# ── Create wrapper script ────────────────────
$WrapperScript = @"
@echo off
java -jar "$AgentJar" -url "$JenkinsUrl" -name "$AgentName" -secret "$Secret" -workDir "$AgentDir" -webSocket
"@
Set-Content -Path "$AgentDir\run-agent.bat" -Value $WrapperScript

# ── Create Windows service using sc.exe ───────
# Using NSSM (Non-Sucking Service Manager) for reliable service wrapping
$NssmPath = "$AgentDir\nssm.exe"
if (-not (Test-Path $NssmPath)) {
    Write-Host "Downloading NSSM..."
    $NssmZip = "$AgentDir\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $NssmZip
    Expand-Archive -Path $NssmZip -DestinationPath "$AgentDir\nssm-tmp" -Force
    Copy-Item "$AgentDir\nssm-tmp\nssm-2.24\win64\nssm.exe" $NssmPath
    Remove-Item -Recurse -Force "$AgentDir\nssm-tmp", $NssmZip
}

& $NssmPath install $ServiceName java
& $NssmPath set $ServiceName AppParameters "-jar `"$AgentJar`" -url `"$JenkinsUrl`" -name `"$AgentName`" -secret `"$Secret`" -workDir `"$AgentDir`" -webSocket"
& $NssmPath set $ServiceName AppDirectory $AgentDir
& $NssmPath set $ServiceName DisplayName "Jenkins Agent ($AgentName)"
& $NssmPath set $ServiceName Description "Jenkins JNLP agent connecting to $JenkinsUrl"
& $NssmPath set $ServiceName Start SERVICE_AUTO_START
& $NssmPath set $ServiceName AppStdout "$AgentDir\agent.log"
& $NssmPath set $ServiceName AppStderr "$AgentDir\agent.log"
& $NssmPath set $ServiceName AppRotateFiles 1
& $NssmPath set $ServiceName AppRotateBytes 10485760

# ── Start service ─────────────────────────────
Start-Service -Name $ServiceName

Write-Host ""
Write-Host "Jenkins JNLP agent installed as Windows service."
Write-Host "  Service: $ServiceName"
Write-Host "  Work dir: $AgentDir"
Write-Host "  Log: $AgentDir\agent.log"
Write-Host ""
Write-Host "Commands:"
Write-Host "  Status:  Get-Service $ServiceName"
Write-Host "  Stop:    Stop-Service $ServiceName"
Write-Host "  Start:   Start-Service $ServiceName"
Write-Host "  Remove:  & `"$NssmPath`" remove $ServiceName confirm"
Write-Host "  Logs:    Get-Content $AgentDir\agent.log -Tail 50"
