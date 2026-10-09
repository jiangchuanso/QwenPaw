# Install the Electron NSIS package, launch the shell headless (to start the
# bundled backend), wait for the backend port, and export BASE_URL to
# $GITHUB_ENV for the verifier step.
#
# Mirrors launch_tauri_windows.ps1 but for the Electron NSIS build. We launch
# headless (no visible window) because the verification drives the SPA with an
# independent Playwright Chromium; the Electron window itself is not inspected.
$ErrorActionPreference = "Stop"

# 1. Silent NSIS install (matches a real user install: /S = silent).
$installer = Get-ChildItem dist/QwenPaw-*-win-*.exe | Select-Object -First 1
if (-not $installer) { throw "Electron NSIS installer not found in dist/" }
Write-Host "Installing $($installer.Name) silently..."
$proc = Start-Process -FilePath $installer.FullName -ArgumentList "/S" `
  -Wait -PassThru -NoNewWindow
Write-Host "Installer exited with code $($proc.ExitCode)"
if ($proc.ExitCode -ne 0) {
  throw "NSIS installer failed (exit $($proc.ExitCode))"
}
# NSIS spawns elevated child + finishes immediately; allow files to settle.
Start-Sleep -Seconds 5

# 2. Locate the installed Electron exe (default productName "QwenPaw").
$exe = $null
$candidateRoots = @(
  (Join-Path $env:LOCALAPPDATA "Programs\QwenPaw"),
  (Join-Path $env:LOCALAPPDATA "QwenPaw"),
  (Join-Path $env:ProgramFiles "QwenPaw"),
  (Join-Path ${env:ProgramFiles(x86)} "QwenPaw")
)
foreach ($root in $candidateRoots) {
  if (Test-Path $root) {
    $found = Get-ChildItem -Path $root -Filter "QwenPaw.exe" `
      -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $exe = $found.FullName; break }
  }
}
if (-not $exe) { throw "Electron exe (QwenPaw.exe) not found after NSIS install" }
Write-Host "Installed at: $exe"

# 3. Launch headless purely to start the backend.
Start-Process -FilePath $exe -ArgumentList "--headless"

# 4. Wait for the sidecar to write the port file and respond.
$portFile = Join-Path $env:USERPROFILE ".qwenpaw\desktop_port"
$port = $null
$backendReady = $false
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $portFile) {
    $port = (Get-Content $portFile -ErrorAction SilentlyContinue).Trim()
    if ($port) {
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/version" `
          -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
          Write-Host "Electron backend ready on port $port"
          $backendReady = $true
          break
        }
      } catch {}
    }
  }
  Start-Sleep -Seconds 2
}
if (-not $backendReady) {
  throw "Electron backend did not start within 180s"
}

# 5. Auto-init creates BOOTSTRAP.md during startup. Remove it afterwards so the
#    verifier can drive the agent in normal QA mode.
$bootstrapMd = Join-Path $env:USERPROFILE ".qwenpaw\workspaces\default\BOOTSTRAP.md"
if (Test-Path $bootstrapMd) { Remove-Item -Force $bootstrapMd }

$baseUrl = "http://127.0.0.1:$port"
"BASE_URL=$baseUrl" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Host "BASE_URL=$baseUrl"
