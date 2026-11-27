$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repo
try {
  & git config core.hooksPath .githooks
  if ($LASTEXITCODE -ne 0) { throw 'git config failed' }
  Write-Host 'Installed git hooks: core.hooksPath=.githooks'
  Write-Host 'Pre-commit runs: dart tool/sync_cli_sources.dart --check --skills'
} finally {
  Pop-Location
}
