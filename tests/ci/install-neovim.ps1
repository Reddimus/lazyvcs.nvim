param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{64}$")]
    [string]$Sha256,

    [Parameter(Mandatory = $true)]
    [string]$Prefix
)

$ErrorActionPreference = "Stop"
$asset = "nvim-win64.zip"
$archive = Join-Path $env:RUNNER_TEMP "$Version-$asset"
$url = "https://github.com/neovim/neovim/releases/download/$Version/$asset"

Invoke-WebRequest -Uri $url -OutFile $archive -MaximumRetryCount 5 -RetryIntervalSec 2
$actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha -ne $Sha256.ToLowerInvariant()) {
    throw "Checksum mismatch for $asset`: expected $Sha256, got $actualSha"
}

New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $Prefix -Force
$nvimBin = Join-Path $Prefix "nvim-win64\bin"
if (-not (Test-Path -LiteralPath (Join-Path $nvimBin "nvim.exe"))) {
    throw "Neovim executable was not extracted under $nvimBin"
}

$nvimBin | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
