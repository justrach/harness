# Native GUI probe: launch the real app on an isolated profile and capture its
# titlebar, so the caption buttons can be seen on a Windows image that lacks
# the Windows 11 "Segoe Fluent Icons" font. No real account/provider data is used.
param([string]$Exe = (Join-Path $PSScriptRoot '../target/release/harness.exe'))
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This probe requires Windows and an interactive desktop' }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../target/windows-titlebar-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $root | Out-Null
Add-Type -AssemblyName System.Drawing
$fluent = [Drawing.Text.InstalledFontCollection]::new().Families | Where-Object { $_.Name -eq 'Segoe Fluent Icons' }
"Segoe Fluent Icons installed: $([bool]$fluent)" | Tee-Object -FilePath (Join-Path $root 'fonts.txt')

$overrides = @{
    HOME = $root; USERPROFILE = $root
    LOCALAPPDATA = (Join-Path $root 'AppData/Local')
    APPDATA = (Join-Path $root 'AppData/Roaming')
    HARNESS_DATA_DIR = (Join-Path $root 'Harness')
    HARNESS_EDGE_TOKEN = $null; HARNESS_IPC_PORT = '0'
    HARNESS_EDGE_URL = 'http://127.0.0.1:1'; HARNESS_ORG_ID = $null
    HARNESS_PROVIDER = 'mock'; RUST_BACKTRACE = '1'
}
foreach ($key in $overrides.Keys) { [Environment]::SetEnvironmentVariable($key, $overrides[$key], 'Process') }

$p = Start-Process -FilePath $Exe -PassThru -RedirectStandardOutput (Join-Path $root 'stdout.txt') -RedirectStandardError (Join-Path $root 'stderr.txt')
try {
    $null = $p.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $p.Refresh()
        if ($p.HasExited) { throw "Harness exited early: $($p.ExitCode)" }
        if ($p.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $hwnd = $p.MainWindowHandle
    if ($hwnd -eq 0) { throw 'Harness did not open a window within 25s' }
    # Let the first frames present before capturing.
    Start-Sleep -Seconds 4
    $capturePath = Join-Path $root 'window.png'
    $metadataPath = Join-Path $root 'window.json'
    $helperPath = Join-Path $PSScriptRoot 'test-windows-capture-client.ps1'
    $shellPath = (Get-Process -Id $PID).Path
    $capture = Start-Process -FilePath $shellPath -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', ('"' + $helperPath + '"'),
        '-WindowHandle', $hwnd.ToInt64(), '-ExpectedProcessId', $p.Id,
        '-OutputFile', ('"' + $capturePath + '"'), '-MetadataFile', ('"' + $metadataPath + '"')
    ) -RedirectStandardOutput (Join-Path $root 'capture.stdout.txt') -RedirectStandardError (Join-Path $root 'capture.stderr.txt')
    if (-not $capture.WaitForExit(15000)) { $capture.Kill(); throw 'Capture timed out after 15s' }
    if ($capture.ExitCode -ne 0) { throw "Capture failed: exit $($capture.ExitCode); see capture.stderr.txt" }
    # The caption buttons sit at the top right: crop that corner at 3x for a readable image.
    $full = [Drawing.Bitmap]::new($capturePath)
    try {
        $w = [math]::Min(360, $full.Width); $h = [math]::Min(64, $full.Height)
        $crop = [Drawing.Bitmap]::new($w * 3, $h * 3)
        $g = [Drawing.Graphics]::FromImage($crop)
        try {
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $g.DrawImage($full, [Drawing.Rectangle]::new(0, 0, $w * 3, $h * 3), [Drawing.Rectangle]::new($full.Width - $w, 0, $w, $h), [Drawing.GraphicsUnit]::Pixel)
        } finally { $g.Dispose() }
        $crop.Save((Join-Path $root 'caption-buttons.png'), [Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()
    } finally { $full.Dispose() }
    "Captured $capturePath" | Write-Host
} finally {
    $p.Refresh()
    if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
}
