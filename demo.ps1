# Laptop-specific Windows shortcut to the Ubuntu WSL demo controls.
param(
    [ValidateSet('start', 'stop', 'status', 'smoke', 'scale', 'infra', 'compose')]
    [string]$Action = 'status',
    [ValidateRange(1, 4)]
    [int]$Workers = 2
)
# Convert this script's Windows drive path to its /mnt/<drive>/... WSL path.
$launcher = Join-Path $PSScriptRoot 'demo.sh'
$wslLauncher = '/mnt/' + $launcher.Substring(0, 1).ToLower() + $launcher.Substring(2).Replace('\', '/')
& wsl.exe -d Ubuntu-26.04 -- bash $wslLauncher $Action $Workers
exit $LASTEXITCODE
