# Build only Luau with the MSVC C++ ABI and static CRT used by native-math.
# Invoked by build.zig for both tests and packaging; no developer shell needed.
param(
    [Parameter(Mandatory)][string]$OutputLibrary,
    [Parameter(Mandatory)][string]$LuauRoot,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][ValidateSet('debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')][string]$Optimize,
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
    $flags += if ($Optimize -eq 'ReleaseSmall') { '/O1' } else { '/O2' }
    if ($Optimize -ne 'ReleaseSafe') { $flags += '/DNDEBUG' }
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
Set-Content -LiteralPath $archiveRsp -Encoding Unicode -Value (@('/nologo', '/OUT:"' + $OutputLibrary + '"') + $objects)

# Expand paths through environment variables, not interpolated cmd source.
$env:HARNESS_LUAU_VSDEVCMD = $devcmd
$env:HARNESS_LUAU_COMPILE_RSP = $compileRsp
$env:HARNESS_LUAU_ARCHIVE_RSP = $archiveRsp
$command = 'call "%HARNESS_LUAU_VSDEVCMD%" -no_logo -host_arch=x64 -arch=' + $Architecture + ' && cl.exe @"%HARNESS_LUAU_COMPILE_RSP%" && lib.exe @"%HARNESS_LUAU_ARCHIVE_RSP%"'
Push-Location -LiteralPath $outDir
try {
    & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) { throw 'MSVC Luau compilation or archive creation failed' }
} finally { Pop-Location }
if (-not (Test-Path -LiteralPath $OutputLibrary)) { throw 'MSVC Luau did not produce its static library' }
