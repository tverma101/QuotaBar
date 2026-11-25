param(
    [Parameter(Mandatory = $true)]
    [string]$Installer
)

$ErrorActionPreference = 'Stop'
$setup = (Resolve-Path -LiteralPath $Installer).Path
$installDir = Join-Path $env:LOCALAPPDATA 'QuotaBar'
$appData = Join-Path $env:APPDATA 'com.tverma101.quotabar'
$uninstall = Join-Path $installDir 'uninstall.exe'

if ((Test-Path -LiteralPath $installDir) -or (Test-Path -LiteralPath $appData) -or
    (Get-Process -Name quotabar -ErrorAction SilentlyContinue)) {
    throw 'Use a disposable Windows user profile with no existing QuotaBar installation or data.'
}

function Invoke-Silent([string]$Executable) {
    $process = Start-Process -FilePath $Executable -ArgumentList '/S' -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "$Executable failed (exit $($process.ExitCode))."
    }
}

try {
    Invoke-Silent $setup
    $desktop = Join-Path $installDir 'quotabar.exe'
    $cli = Join-Path $installDir 'quotabar-cli.exe'
    $provider = Join-Path $installDir 'resources\bundled_plugins\codex\plugin.json'
    foreach ($file in @($desktop, $cli, $provider, $uninstall)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Installer did not stage $file."
        }
    }

    $help = & $cli --help | Out-String
    if ($LASTEXITCODE -ne 0 -or $help -notmatch 'Usage: quotabar-cli') {
        throw 'The installed CLI could not run.'
    }
    New-Item -ItemType Directory -Path $appData | Out-Null
    @{
        version = 1
        snapshots = @{
            codex = @{
                providerId = 'codex'
                displayName = 'Codex'
                plan = 'Installer Smoke Fixture'
                fetchedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                lines = @()
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding Ascii (Join-Path $appData 'usage-api-cache.json')
    $limits = & $cli read codex | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $limits.providers.codex.plan -ne 'Installer Smoke Fixture' -or
        $limits.providers.codex.stale -ne $false) {
        throw 'The installed CLI did not reuse the seeded fresh snapshot.'
    }
    Write-Host 'Installed desktop app, provider resources, and CLI; verified fresh cached limits.'
} finally {
    try {
        if (Test-Path -LiteralPath $uninstall -PathType Leaf) {
            Invoke-Silent $uninstall
        }
    } finally {
        if (Test-Path -LiteralPath $appData) {
            Remove-Item -LiteralPath $appData -Recurse -Force
        }
    }
}

if ((Test-Path -LiteralPath $desktop) -or (Test-Path -LiteralPath $cli)) {
    throw 'Uninstall left an installed app or CLI executable.'
}
Write-Host 'Uninstall removed both executables.'
