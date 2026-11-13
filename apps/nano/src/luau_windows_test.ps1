# Windows-only integration regression for the build helper. Run with the same
# powershell.exe 5.1 and installed MSVC toolset as the UI and packaging builds.
param(
    [Parameter(Mandatory)][string]$Helper,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$Helper = [IO.Path]::GetFullPath($Helper)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
# Spaces exercise WorkingDirectory/response-file handling without depending on
# the checkout's name. No app data or downloaded source is used by this test.
$root = Join-Path $OutputDirectory 'synthetic Luau source'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$source = Join-Path $root 'fixture.cpp'
Set-Content -LiteralPath $source -Encoding ASCII -Value @'
#if LUA_USE_LONGJMP != 1 || LUA_VECTOR_SIZE != 3 || LUAI_MAXCSTACK != 1000000
#error Luau C API configuration changed
#endif
LUA_API int luau_build_fixture(void) { return 3; }
LUACODE_API int luau_compile_fixture(void) { return 1; }
'@
foreach ($mode in @('debug', 'safe', 'fast', 'small')) {
    $out = Join-Path $OutputDirectory "$mode output/luau.lib"
    & $Helper -OutputLibrary $out -LuauRoot $root -Architecture x64 -Optimize $mode $source
    if (-not (Test-Path -LiteralPath $out)) { throw "$mode failed to create the fixture archive" }
    $flags = Get-Content -LiteralPath (Join-Path (Split-Path $out -Parent) 'compile.rsp')
    $archiveFlags = Get-Content -LiteralPath (Join-Path (Split-Path $out -Parent) 'archive.rsp')
    if ($archiveFlags -notcontains ('/OUT:"' + $out + '"')) { throw "$mode split the archive output argument" }
    if ($flags -notcontains '/MT' -or $flags -contains '/MD' -or $flags -notcontains '/D_ITERATOR_DEBUG_LEVEL=0') {
        throw "$mode selected an incompatible CRT/STL layout"
    }
    $expectedOptimization = switch ($mode) { 'debug' { '/Od' } 'small' { '/O1' } default { '/O2' } }
    if ($flags -notcontains $expectedOptimization) { throw "$mode selected the wrong compiler optimization" }
    $expectNdebug = $mode -in @('fast', 'small')
    if (($flags -contains '/DNDEBUG') -ne $expectNdebug) { throw "$mode selected the wrong assertion behavior" }
    if (($flags -contains '/Z7') -ne ($mode -eq 'debug')) { throw "$mode selected the wrong debug information" }
}
Write-Host '[Luau] Windows helper integration passed for debug/safe/fast/small'
