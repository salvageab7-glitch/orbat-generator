param(
  [switch]$Check,
  [switch]$Skills,
  [string]$Dart = ''
)

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Dart)) {
  $dartCmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($dartCmd) {
    $Dart = $dartCmd.Source
  } elseif (Test-Path -LiteralPath 'C:\flutter\bin\cache\dart-sdk\bin\dart.exe') {
    $Dart = 'C:\flutter\bin\cache\dart-sdk\bin\dart.exe'
  } else {
    throw 'dart not found. Pass -Dart <path> or add Dart to PATH.'
  }
}

if (-not (Test-Path -LiteralPath $Dart)) {
  throw "dart not found: $Dart"
}

$toolArgs = @('run', 'tool/sync_cli_sources.dart')
if ($Check) { $toolArgs += '--check' }
if ($Skills) { $toolArgs += '--skills' }

Push-Location $app
try {
  & $Dart @toolArgs
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
