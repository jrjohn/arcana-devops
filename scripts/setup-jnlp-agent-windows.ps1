# Set up Jenkins JNLP agent on Windows as a Scheduled Task (auto-start at logon)
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
$TaskName = "JenkinsAgent"

# ── Check admin ───────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# ── Check Java ────────────────────────────────
$JavaPath = (Get-Command java -ErrorAction SilentlyContinue).Source
if (-not $JavaPath) {
    Write-Error "Java not found. Install Java 17+: winget install Microsoft.OpenJDK.17"
    exit 1
}
Write-Host "Java found: $JavaPath"

# ── Setup directory ───────────────────────────
Write-Host "Setting up Jenkins JNLP agent..."
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

# ── Download agent.jar ────────────────────────
Write-Host "Downloading agent.jar..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "${JenkinsUrl}jnlpJars/agent.jar" -OutFile $AgentJar

if (-not (Test-Path $AgentJar)) {
    Write-Error "Failed to download agent.jar"
    exit 1
}

# ── Create wrapper script ─────────────────────
$WrapperScript = @"
@echo off
:loop
"$JavaPath" -jar "$AgentJar" -url "$JenkinsUrl" -name "$AgentName" -secret "$Secret" -workDir "$AgentDir" -webSocket
echo Agent exited, restarting in 10 seconds...
timeout /t 10 /nobreak >nul
goto loop
"@
Set-Content -Path "$AgentDir\run-agent.bat" -Value $WrapperScript -Encoding ASCII

# ── Remove existing scheduled task ────────────
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing scheduled task..."
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Start-Sleep -Seconds 2
}

# ── Create scheduled task ─────────────────────
Write-Host "Creating scheduled task..."
$Action = New-ScheduledTaskAction -Execute "$AgentDir\run-agent.bat" -WorkingDirectory $AgentDir
$Trigger = New-ScheduledTaskTrigger -AtLogon
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 999 `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Principal $Principal -Description "Jenkins JNLP agent connecting to $JenkinsUrl" | Out-Null

# ── Start the task now ────────────────────────
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

# ── Verify ────────────────────────────────────
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ""
Write-Host "Jenkins JNLP agent installed as Scheduled Task."
Write-Host "  Task: $TaskName (Status: $($task.State))"
Write-Host "  Work dir: $AgentDir"
Write-Host "  Log: $AgentDir\agent.log (if configured)"
Write-Host ""
Write-Host "Commands:"
Write-Host "  Status:  Get-ScheduledTask -TaskName $TaskName"
Write-Host "  Stop:    Stop-ScheduledTask -TaskName $TaskName"
Write-Host "  Start:   Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Remove:  Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
Write-Host "  Logs:    Get-Content $AgentDir\agent.log -Tail 50"
