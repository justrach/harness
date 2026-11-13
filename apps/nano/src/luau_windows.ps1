# Build only Luau with the MSVC C++ ABI and static CRT used by native-math.
# Invoked by build.zig for both tests and packaging; no developer shell needed.
param(
    [Parameter(Mandatory)][string]$OutputLibrary,
    [Parameter(Mandatory)][string]$LuauRoot,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][ValidateSet('debug', 'safe', 'fast', 'small')][string]$Optimize,
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Sources
)
$ErrorActionPreference = 'Stop'
# Resolve build-runner paths before entering the object output directory.
$OutputLibrary = [IO.Path]::GetFullPath($OutputLibrary)
$LuauRoot = [IO.Path]::GetFullPath($LuauRoot)
$Sources = @($Sources | ForEach-Object { [IO.Path]::GetFullPath($_) })

# Discover VS even in the plain PowerShell sessions used by the UI CI job.
# Always enter its environment: an existing developer prompt may target a
# different architecture, and cl.exe/lib.exe must come from the same toolset.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'MSVC Luau requires Visual Studio Build Tools with the C++ desktop workload'
}
$component = if ($Architecture -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
$installation = & $vswhere -latest -products '*' -requires $component -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Cannot locate the requested MSVC C++ toolset' }
$devcmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devcmd)) { throw 'Cannot locate the MSVC developer environment' }

$outDir = Split-Path -Parent $OutputLibrary
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$compileRsp = Join-Path $outDir 'compile.rsp'
$archiveRsp = Join-Path $outDir 'archive.rsp'
# Response files avoid cmd.exe's command-line limit and keep paths with spaces
# out of its parser. /MT (not /MTd, even in Debug) matches Rust's +crt-static;
# debug iterators would otherwise change the STL ABI and select debug runtimes.
$flags = @('/nologo', '/c', '/std:c++17', '/EHsc', '/MT', '/Zc:__cplusplus', '/utf-8',
    '/D_ITERATOR_DEBUG_LEVEL=0', '/DLUA_USE_LONGJMP=1', '/DLUAI_MAXCSTACK=1000000', '/DLUA_VECTOR_SIZE=3',
    '/DLUA_API="extern \"C\""', '/DLUACODE_API="extern \"C\""')
if ($Optimize -eq 'debug') { $flags += @('/Od', '/Z7') }
else {
    # Keep assertions in ReleaseSafe, as in the Zig C++ build. Never use /GL:
    # the archive is consumed by Zig's COFF linker, not MSVC's LTCG linker.
    $flags += if ($Optimize -eq 'small') { '/O1' } else { '/O2' }
    if ($Optimize -ne 'safe') { $flags += '/DNDEBUG' }
}
foreach ($include in @('Common', 'Ast', 'Bytecode', 'Compiler', 'VM')) {
    $flags += '/I"' + (Join-Path $LuauRoot "$include/include") + '"'
}
$flags += $Sources | ForEach-Object { '"' + $_ + '"' }
$objects = $Sources | ForEach-Object { '"' + [IO.Path]::GetFileNameWithoutExtension($_) + '.obj"' }
# All selected Luau translation units must have distinct object basenames.
if (@($objects | Select-Object -Unique).Count -ne $Sources.Count) { throw 'Luau object filenames collide' }
# MSVC response files accept a UTF-16 BOM, including non-ASCII checkout paths.
Set-Content -LiteralPath $compileRsp -Encoding Unicode -Value $flags
Set-Content -LiteralPath $archiveRsp -Encoding Unicode -Value (@('/nologo', ('/OUT:"' + $OutputLibrary + '"')) + $objects)

# Do not pass an inline, nested-quoted command through PowerShell 5.1's
# native-argument marshaller. cmd /s strips quotes again, so a command that
# works under PowerShell 7 can silently fail before invoking cl under 5.1.
# A fixed, unquoted batch basename plus ProcessStartInfo's raw Arguments
# removes both quoting layers, including when the output path has spaces.
$batch = @'
@echo off
setlocal
echo [Luau] Initializing MSVC environment
call "%HARNESS_LUAU_VSDEVCMD%" -no_logo -host_arch=x64 -arch=%HARNESS_LUAU_ARCH%
set "HARNESS_LUAU_EXIT=%ERRORLEVEL%"
if not "%HARNESS_LUAU_EXIT%"=="0" goto environment_failed
rem VsDevCmd may change directories. All object basenames must land here.
cd /d "%HARNESS_LUAU_OUTPUT_DIR%"
if errorlevel 1 exit /b 1
where /q cl.exe
if errorlevel 1 goto compiler_missing
where /q lib.exe
if errorlevel 1 goto librarian_missing
echo [Luau] Compiling with MSVC static CRT
cl.exe @"%HARNESS_LUAU_COMPILE_RSP%"
set "HARNESS_LUAU_EXIT=%ERRORLEVEL%"
if not "%HARNESS_LUAU_EXIT%"=="0" goto compile_failed
echo [Luau] Creating static archive
lib.exe @"%HARNESS_LUAU_ARCHIVE_RSP%"
set "HARNESS_LUAU_EXIT=%ERRORLEVEL%"
if not "%HARNESS_LUAU_EXIT%"=="0" goto archive_failed
exit /b 0
:environment_failed
echo [Luau] VsDevCmd failed with exit code %HARNESS_LUAU_EXIT% 1>&2
exit /b %HARNESS_LUAU_EXIT%
:compiler_missing
echo [Luau] VsDevCmd did not provide cl.exe 1>&2
exit /b 1
:librarian_missing
echo [Luau] VsDevCmd did not provide lib.exe 1>&2
exit /b 1
:compile_failed
echo [Luau] cl.exe failed with exit code %HARNESS_LUAU_EXIT% 1>&2
exit /b %HARNESS_LUAU_EXIT%
:archive_failed
echo [Luau] lib.exe failed with exit code %HARNESS_LUAU_EXIT% 1>&2
exit /b %HARNESS_LUAU_EXIT%
'@
# This batch contains only ASCII; non-ASCII paths travel in the environment
# and UTF-16 compiler response files, never in cmd's source-code encoding.
$batch = $batch.Replace("`r`n", "`n").Replace("`n", "`r`n")
Set-Content -LiteralPath (Join-Path $outDir 'luau-build.cmd') -Encoding ASCII -Value $batch
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $env:ComSpec
$start.Arguments = '/d /s /c luau-build.cmd'
$start.WorkingDirectory = $outDir
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.EnvironmentVariables['HARNESS_LUAU_VSDEVCMD'] = $devcmd
$start.EnvironmentVariables['HARNESS_LUAU_ARCH'] = $Architecture
$start.EnvironmentVariables['HARNESS_LUAU_OUTPUT_DIR'] = $outDir
$start.EnvironmentVariables['HARNESS_LUAU_COMPILE_RSP'] = $compileRsp
$start.EnvironmentVariables['HARNESS_LUAU_ARCHIVE_RSP'] = $archiveRsp
Write-Host "[Luau] Starting MSVC build ($Architecture, $Optimize)"
$process = [Diagnostics.Process]::Start($start)
try {
    # Drain both pipes concurrently: cl diagnostics can otherwise fill stderr
    # while the parent is blocked waiting on stdout or process completion.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if ($stdout.Result) { [Console]::Out.Write($stdout.Result) }
    if ($stderr.Result) { [Console]::Error.Write($stderr.Result) }
    if ($process.ExitCode -ne 0) {
        throw "MSVC Luau build failed with exit code $($process.ExitCode); see the stage diagnostic above"
    }
} finally { $process.Dispose() }
if (-not (Test-Path -LiteralPath $OutputLibrary)) { throw 'MSVC Luau did not produce its static library' }
