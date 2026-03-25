$ErrorActionPreference = "SilentlyContinue"

$stateDir = Join-Path $HOME ".remote-jupyter"
$pidFiles = @(
    (Join-Path $stateDir "tunnel.pid"),
    (Join-Path $stateDir "jupyter.pid")
)

foreach ($pidFile in $pidFiles) {
    if (-not (Test-Path $pidFile)) {
        continue
    }

    $pidValue = (Get-Content $pidFile | Select-Object -First 1).Trim()
    if ($pidValue -match '^\d+$') {
        Stop-Process -Id ([int]$pidValue) -Force
    }
    Remove-Item $pidFile -Force
}

Write-Host "Stopped remote Jupyter processes if they were running."
