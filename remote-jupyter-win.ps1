param(
    [string]$WorkDir = "$HOME",
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Add-PathIfMissing {
    param([string]$PathToAdd)
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) { return }
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($current) {
        $parts = $current -split ";"
    }
    if ($parts -notcontains $PathToAdd) {
        $newPath = (($parts + $PathToAdd) | Where-Object { $_ } | Select-Object -Unique) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
    if (($env:Path -split ";") -notcontains $PathToAdd) {
        $env:Path = "$PathToAdd;$env:Path"
    }
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}

function Require-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is required on Windows 11. Install App Installer from Microsoft Store first."
    }
}

function Ensure-WingetPackage {
    param(
        [string]$CommandName,
        [string]$PackageId,
        [string]$DisplayName,
        [string[]]$ExtraPaths = @()
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        return
    }

    Write-Section "Installing $DisplayName"
    winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --scope user --silent

    Refresh-SessionPath
    foreach ($path in $ExtraPaths) {
        Add-PathIfMissing $path
    }

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "$DisplayName was installed, but '$CommandName' is still not on PATH. Open a new terminal and retry once."
    }
}

function Ensure-Node {
    Ensure-WingetPackage -CommandName "node" -PackageId "OpenJS.NodeJS.LTS" -DisplayName "Node.js LTS" -ExtraPaths @(
        "$HOME\AppData\Local\Programs\nodejs"
    )
}

function Ensure-Python {
    Ensure-WingetPackage -CommandName "python" -PackageId "Python.Python.3.12" -DisplayName "Python 3.12" -ExtraPaths @(
        "$HOME\AppData\Local\Programs\Python\Python312",
        "$HOME\AppData\Local\Programs\Python\Python312\Scripts"
    )
}

function Ensure-Pip {
    Write-Section "Checking pip"
    & python -m ensurepip --upgrade | Out-Host
    & python -m pip install --user --upgrade pip setuptools wheel | Out-Host
    Refresh-SessionPath
    $userScripts = & python -c "import site; print(site.USER_BASE)"
    Add-PathIfMissing (Join-Path $userScripts "Scripts")
}

function Ensure-JupyterLab {
    $hasJupyter = $false
    try {
        & python -m jupyterlab --version | Out-Null
        $hasJupyter = $true
    } catch {
        $hasJupyter = $false
    }

    if (-not $hasJupyter) {
        Write-Section "Installing JupyterLab"
        & python -m pip install --user --upgrade jupyterlab notebook | Out-Host
    }
}

function Get-VenvPaths {
    param([string]$BaseDir)
    $venvDir = Join-Path $BaseDir ".venv-gpu"
    $pythonExe = Join-Path $venvDir "Scripts\python.exe"
    $pipExe = Join-Path $venvDir "Scripts\pip.exe"
    return @{
        VenvDir = $venvDir
        PythonExe = $pythonExe
        PipExe = $pipExe
    }
}

function Ensure-Venv {
    param([string]$BaseDir)
    $paths = Get-VenvPaths -BaseDir $BaseDir
    if (-not (Test-Path $paths.PythonExe)) {
        Write-Section "Creating GPU virtual environment"
        & python -m venv $paths.VenvDir | Out-Host
    }

    & $paths.PythonExe -m pip install --upgrade pip setuptools wheel | Out-Host
    return $paths
}

function Ensure-TorchGpu {
    param([hashtable]$VenvPaths)

    $torchChannel = if ($env:TORCH_CUDA_CHANNEL) { $env:TORCH_CUDA_CHANNEL } else { "cu128" }
    $torchIndex = "https://download.pytorch.org/whl/$torchChannel"

    Write-Section "Installing PyTorch GPU stack ($torchChannel)"
    & $VenvPaths.PythonExe -m pip install --upgrade `
        torch torchvision torchaudio `
        --index-url $torchIndex | Out-Host

    Write-Section "Installing notebook kernel tools"
    & $VenvPaths.PythonExe -m pip install --upgrade ipykernel jupyterlab notebook | Out-Host

    Write-Section "Registering Jupyter kernel"
    & $VenvPaths.PythonExe -m ipykernel install --user --name "remote-gpu" --display-name "Python (.venv-gpu)" | Out-Host

    Write-Section "Validating CUDA availability"
    & $VenvPaths.PythonExe -c "import torch; print('torch', torch.__version__); print('cuda', torch.cuda.is_available()); print('devices', torch.cuda.device_count())" | Out-Host
}

function Ensure-Cloudflared {
    Ensure-WingetPackage -CommandName "cloudflared" -PackageId "Cloudflare.cloudflared" -DisplayName "cloudflared" -ExtraPaths @(
        "$HOME\AppData\Local\Microsoft\WinGet\Packages\Cloudflare.cloudflared_Microsoft.Winget.Source_8wekyb3d8bbwe"
    )
}

function Ensure-Ngrok {
    if (Get-Command ngrok -ErrorAction SilentlyContinue) {
        return
    }

    try {
        Ensure-WingetPackage -CommandName "ngrok" -PackageId "Ngrok.Ngrok" -DisplayName "ngrok"
    } catch {
        Write-Warning "ngrok auto-install failed. cloudflared quick tunnel will still work."
    }
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $value = ($listener.LocalEndpoint).Port
    $listener.Stop()
    return $value
}

function New-Token {
    return [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }))
        .TrimEnd("=")
        .Replace("+", "A")
        .Replace("/", "B")
}

function Wait-ForUrl {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }

    return $false
}

function Read-TryCloudflareUrl {
    param([string[]]$LogPaths)
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        foreach ($logPath in $LogPaths) {
            if (Test-Path $logPath) {
                $match = Select-String -Path $logPath -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" -AllMatches -ErrorAction SilentlyContinue
                if ($match.Matches.Count -gt 0) {
                    return $match.Matches[0].Value
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Read-NgrokUrl {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 3
            $httpsTunnel = $resp.tunnels | Where-Object { $_.public_url -like "https://*" } | Select-Object -First 1
            if ($httpsTunnel) {
                return $httpsTunnel.public_url
            }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Ensure-UserEnv {
    Write-Section "Setting user environment"
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "User")
    [Environment]::SetEnvironmentVariable("PIP_DISABLE_PIP_VERSION_CHECK", "1", "User")
    [Environment]::SetEnvironmentVariable("JUPYTER_ENABLE_LAB", "yes", "User")
    $env:PYTHONUTF8 = "1"
    $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
    $env:JUPYTER_ENABLE_LAB = "yes"
}

function Stop-ProcessFromFile {
    param([string]$PidFile)
    if (-not (Test-Path $PidFile)) {
        return
    }

    $pidValue = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($pidValue -match '^\d+$') {
        try {
            Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

Require-Winget
Ensure-UserEnv
Ensure-Node
Ensure-Python
Ensure-Pip
Ensure-JupyterLab
Ensure-Cloudflared
Ensure-Ngrok

$resolvedWorkDir = [Environment]::ExpandEnvironmentVariables($WorkDir)
if (-not (Test-Path $resolvedWorkDir)) {
    New-Item -ItemType Directory -Path $resolvedWorkDir -Force | Out-Null
}

$stateDir = Join-Path $HOME ".remote-jupyter"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

$jupyterLog = Join-Path $stateDir "jupyter.log"
$tunnelLog = Join-Path $stateDir "tunnel.log"
$tokenFile = Join-Path $stateDir "token.txt"
$jupyterPidFile = Join-Path $stateDir "jupyter.pid"
$tunnelPidFile = Join-Path $stateDir "tunnel.pid"
$jupyterErrLog = Join-Path $stateDir "jupyter.err.log"
$tunnelErrLog = Join-Path $stateDir "tunnel.err.log"

Stop-ProcessFromFile -PidFile $jupyterPidFile
Stop-ProcessFromFile -PidFile $tunnelPidFile

$venvPaths = Ensure-Venv -BaseDir $resolvedWorkDir
Ensure-TorchGpu -VenvPaths $venvPaths

if ($Port -le 0) {
    $Port = Get-FreePort
}

$token = New-Token
Set-Content -Path $tokenFile -Value $token -Encoding ascii

Write-Section "Starting JupyterLab"
$jupyterProc = Start-Process -FilePath $venvPaths.PythonExe `
    -ArgumentList @(
        "-m", "jupyterlab",
        "--no-browser",
        "--ServerApp.ip=127.0.0.1",
        "--ServerApp.port=$Port",
        "--ServerApp.port_retries=0",
        "--ServerApp.token=$token",
        "--IdentityProvider.token=$token",
        "--ServerApp.allow_remote_access=True",
        "--ServerApp.allow_origin=*",
        "--ServerApp.disable_check_xsrf=True"
    ) `
    -WorkingDirectory $resolvedWorkDir `
    -RedirectStandardOutput $jupyterLog `
    -RedirectStandardError $jupyterErrLog `
    -WindowStyle Hidden `
    -PassThru

Set-Content -Path $jupyterPidFile -Value $jupyterProc.Id -Encoding ascii

$localUrl = "http://127.0.0.1:$Port/lab?token=$token"
if (-not (Wait-ForUrl -Url $localUrl)) {
    throw "JupyterLab did not become ready. Check $jupyterLog"
}

$publicUrl = $null

Write-Section "Starting tunnel"
try {
    $cloudflaredProc = Start-Process -FilePath "cloudflared" `
        -ArgumentList @("tunnel", "--url", "http://127.0.0.1:$Port") `
        -RedirectStandardOutput $tunnelLog `
        -RedirectStandardError $tunnelErrLog `
        -WindowStyle Hidden `
        -PassThru
    Set-Content -Path $tunnelPidFile -Value $cloudflaredProc.Id -Encoding ascii
    $publicUrl = Read-TryCloudflareUrl -LogPaths @($tunnelErrLog, $tunnelLog)
} catch {
    Write-Warning "cloudflared tunnel failed: $($_.Exception.Message)"
}

if (-not $publicUrl -and (Get-Command ngrok -ErrorAction SilentlyContinue)) {
    if (-not [string]::IsNullOrWhiteSpace($env:NGROK_AUTHTOKEN)) {
        & ngrok config add-authtoken $env:NGROK_AUTHTOKEN | Out-Host
    }

    $ngrokProc = Start-Process -FilePath "ngrok" `
        -ArgumentList @("http", "127.0.0.1:$Port", "--log=stdout") `
        -RedirectStandardOutput $tunnelLog `
        -RedirectStandardError $tunnelErrLog `
        -WindowStyle Hidden `
        -PassThru
    Set-Content -Path $tunnelPidFile -Value $ngrokProc.Id -Encoding ascii
    $publicUrl = Read-NgrokUrl
}

function Get-ShortUrls {
    param([string]$LongUrl)
    $encoded = [System.Uri]::EscapeDataString($LongUrl)
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    $results = @()

    # clck.ru
    try {
        $resp = Invoke-WebRequest -Uri "https://clck.ru/--?url=$encoded" -UseBasicParsing -TimeoutSec 8 -UserAgent $ua
        $result = $resp.Content.Trim()
        if ($result -like "http*") { $results += @{ Name="clck.ru"; Url=$result } }
    } catch {}

    # lrl.kr
    try {
        $body = @{ url = $LongUrl } | ConvertTo-Json
        $resp = Invoke-WebRequest -Uri "https://lrl.kr/api/short" -Method POST -Body $body -ContentType "application/json; charset=UTF-8" -UseBasicParsing -TimeoutSec 8 -UserAgent $ua
        $data = $resp.Content | ConvertFrom-Json
        if ($data.result -like "http*") { $results += @{ Name="lrl.kr"; Url=$data.result } }
        elseif ($data.result) { $results += @{ Name="lrl.kr"; Url="https://lrl.kr/$($data.result)" } }
    } catch {}

    return $results
}

function Show-QrCode {
    param([string]$Text)
    try {
        $env:QR_DATA = $Text
        & $venvPaths.PythonExe -c @"
import os, sys
try:
    import qrcode
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'qrcode'])
    import qrcode
qr = qrcode.QRCode(box_size=1, border=1)
qr.add_data(os.environ['QR_DATA'])
qr.make(fit=True)
qr.print_ascii(invert=True)
"@ | Out-Host
    } catch {
        Write-Warning "QR code generation failed."
    }
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  JupyterLab is running." -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""
Write-Host "Local URL : $localUrl"
if ($publicUrl) {
    $fullPublicUrl = "$publicUrl?token=$token"
    Write-Host "Public URL: $fullPublicUrl"
    $shorts = Get-ShortUrls -LongUrl $fullPublicUrl
    if ($shorts.Count -gt 0) {
        foreach ($s in $shorts) {
            Write-Host "Short URL  ($($s.Name)): $($s.Url)" -ForegroundColor Yellow
        }
        $best = ($shorts | Sort-Object { $_.Url.Length } | Select-Object -First 1).Url
        Set-Clipboard -Value $best
        Write-Host "  (clipboard copied!)" -ForegroundColor Green
        Write-Host ""
        Write-Host "Scan QR code to open:" -ForegroundColor Cyan
        Show-QrCode -Text $best
    } else {
        Set-Clipboard -Value $fullPublicUrl
        Write-Host "  (clipboard copied!)" -ForegroundColor Green
        Write-Host ""
        Write-Host "Scan QR code to open:" -ForegroundColor Cyan
        Show-QrCode -Text $fullPublicUrl
    }
} else {
    Write-Host "Public URL: unavailable"
    Write-Host "Tunnel log: $tunnelLog"
    Write-Host "If your school network blocks tunnels, try a different network or set NGROK_AUTHTOKEN first."
}
Write-Host ""
Write-Host "Work dir  : $resolvedWorkDir"
Write-Host "Venv path : $($venvPaths.VenvDir)"
Write-Host "Jupyter log: $jupyterLog"
Write-Host ""
Write-Host "Press Enter to close this window. Jupyter and tunnel will keep running." -ForegroundColor Yellow
[void][System.Console]::ReadLine()
