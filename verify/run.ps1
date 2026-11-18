# Windows wrapper: runs verify/run.sh with Git Bash (preferred) or another bash.
#   powershell -File verify\run.ps1
#
# Git Bash is preferred on purpose: "bash" on PATH is often C:\Windows\System32\bash.exe,
# the WSL launcher, which fails when no WSL distribution is installed.
$candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
$gitForWindows = Get-Command git -ErrorAction SilentlyContinue
if ($gitForWindows) {
    $candidates += (Join-Path (Split-Path (Split-Path $gitForWindows.Source)) 'bin\bash.exe')
}
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($onPath) { $bash = $onPath.Source }
}
if (-not $bash) {
    Write-Error "bash not found. Install Git for Windows (Git Bash) or WSL, or run: bash verify/run.sh"
    exit 1
}
& $bash (Join-Path $PSScriptRoot 'run.sh')
exit $LASTEXITCODE
