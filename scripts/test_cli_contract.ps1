# CLI 进程级契约冒烟测试（Windows / PowerShell）。
#
# 不打包 app，不重编 CLI；用 `dart run lib/cli/main.dart` 启动真实进程，
# 验证 stdout 单 JSON、退出码、输入优先级与 edit/audit 的行为。
#
# 用法：
#   pwsh -File app/scripts/test_cli_contract.ps1
#   pwsh -File app/scripts/test_cli_contract.ps1 -Dart C:\flutter\bin\cache\dart-sdk\bin\dart.exe
#
# 退出码：0 全部通过；1 有失败。

param(
  [string]$Dart = ''
)

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $app 'cli_aot\lib\cli\main.dart'
if (-not (Test-Path -LiteralPath $cli)) {
  throw "找不到 CLI 源码：$cli"
}

if ([string]::IsNullOrWhiteSpace($Dart)) {
  $dartCmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($dartCmd) {
    $Dart = $dartCmd.Source
  } elseif (Test-Path -LiteralPath 'C:\flutter\bin\cache\dart-sdk\bin\dart.exe') {
    $Dart = 'C:\flutter\bin\cache\dart-sdk\bin\dart.exe'
  } else {
    throw '找不到 dart。请把 dart 加入 PATH，或用 -Dart 指定。'
  }
}
if (-not (Test-Path -LiteralPath $Dart)) {
  throw "dart 不存在：$Dart"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('orbat_cli_contract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$script:failures = 0
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-CaseResult {
  param([string]$Name, [bool]$Passed, [string]$Detail = '')
  if ($Passed) {
    Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
  } else {
    Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
    if ($Detail) { Write-Host ("      {0}" -f $Detail) -ForegroundColor DarkGray }
    $script:failures++
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw ("{0}（期望 {1}，实际 {2}）" -f $Message, $Expected, $Actual)
  }
}

function Invoke-Cli {
  param(
    [string[]]$CliArgs,
    [string]$StdinText = $null,
    [string]$Name = 'case'
  )
  $errFile = Join-Path $tmp ("$Name.err.txt")
  if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force }
  $oldOutputEncoding = $OutputEncoding
  $oldEap = $ErrorActionPreference
  try {
    # Windows PowerShell 会把原生 stderr 当成 error record；这里必须临时 Continue，
    # 否则 help 这类“先写 stderr 再写 stdout”的命令会在 Stop 模式下被中断。
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = $utf8NoBom
    if ($null -ne $StdinText) {
      $out = $StdinText | & $Dart run $cli @CliArgs 2>$errFile
    } else {
      $out = & $Dart run $cli @CliArgs 2>$errFile
    }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEap
    $OutputEncoding = $oldOutputEncoding
  }
  $text = ($out | Out-String).Trim()
  $errText = ''
  if (Test-Path -LiteralPath $errFile) {
    $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $errText) { $errText = '' }
  }
  return [pscustomobject]@{
    Code = $code
    Text = $text
    Err = $errText.Trim()
  }
}

function Get-CliJson {
  param($Result, [string]$Name)
  if ([string]::IsNullOrWhiteSpace($Result.Text)) {
    throw ("{0}: stdout 为空（exit {1}；stderr: {2}）" -f $Name, $Result.Code, $Result.Err)
  }
  try {
    return ($Result.Text | ConvertFrom-Json)
  } catch {
    $preview = $Result.Text
    if ($preview.Length -gt 240) { $preview = $preview.Substring(0, 240) + '…' }
    throw ("{0}: stdout 不是单个 JSON（exit {1}）：{2}" -f $Name, $Result.Code, $preview)
  }
}

function Run-Case {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body
    Write-CaseResult -Name $Name -Passed $true
  } catch {
    Write-CaseResult -Name $Name -Passed $false -Detail $_.Exception.Message
  }
}

try {
  $fixture = Join-Path $tmp 'p0-smoke.json'
  Copy-Item -LiteralPath (Join-Path $app '..\dsh-orbat-plugin\test\p0-smoke.json') -Destination $fixture
  $fixtureText = [IO.File]::ReadAllText($fixture)

  # 带 UTF-8 BOM 的副本，验证 --in 路径会去 BOM。
  $bomFixture = Join-Path $tmp 'p0-smoke-bom.json'
  [IO.File]::WriteAllText($bomFixture, ([char]0xFEFF + $fixtureText), $utf8NoBom)

  # 红牌样本：注释 40 个汉字，超过 12 汉字上限。
  $redFixture = Join-Path $tmp 'p0-smoke-red.json'
  $redObj = $fixtureText | ConvertFrom-Json
  $redObj.subOrganizations[0].options.additionalInformation = ('超长注释' * 10)
  [IO.File]::WriteAllText($redFixture, ($redObj | ConvertTo-Json -Depth 20), $utf8NoBom)

  Run-Case 'version：--version 返回版本与协议号' {
    $r = Invoke-Cli -CliArgs @('--version') -Name 'version'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'version'
    Assert-Equal $j.command 'version' 'command'
    Assert-Equal $j.data.version '0.3.6' 'version'
    Assert-Equal $j.data.protocol 1 'protocol'
    Assert-True ($r.Text.StartsWith('{') -and $r.Text.EndsWith('}')) 'stdout 不是单个 JSON 对象'
  }

  Run-Case 'help：包含 tutorial / --strict / --adapt-for-render' {
    $r = Invoke-Cli -CliArgs @('--help') -Name 'help'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'help'
    Assert-Equal $j.command 'help' 'command'
    Assert-True ($j.data.usage -match 'tutorial') 'help 缺少 tutorial'
    Assert-True ($j.data.usage -match '--strict') 'help 缺少 --strict'
    Assert-True ($j.data.usage -match '--adapt-for-render') 'help 缺少 --adapt-for-render'
  }

  Run-Case 'validate --in：BOM 文件仍能解析' {
    $r = Invoke-Cli -CliArgs @('validate', '--in', $bomFixture) -Name 'validate-bom'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'validate-bom'
    Assert-Equal $j.data.redCount 0 'redCount'
  }

  Run-Case 'normalize --adapt-for-render：返回 echelonFixed' {
    $r = Invoke-Cli -CliArgs @('normalize', '--in', $fixture, '--adapt-for-render') -Name 'normalize'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'normalize'
    Assert-Equal $j.data.echelonFixed 1 'echelonFixed'
  }

  Run-Case 'edit stdin：无 --out 时返回 data.json' {
    $r = Invoke-Cli -CliArgs @('edit', '--path', '师部及师部营', '--note', '契约测试') -StdinText $fixtureText -Name 'edit'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'edit'
    Assert-Equal $j.data.applied 1 'applied'
    Assert-True ($null -ne $j.data.json) '缺少 data.json'
  }

  Run-Case '输入优先级：--in 存在时忽略 stdin' {
    $r = Invoke-Cli -CliArgs @('validate', '--in', $fixture) -StdinText 'not-json' -Name 'precedence'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'precedence'
    Assert-Equal $j.data.redCount 0 'redCount'
  }

  Run-Case 'audit 默认：红牌只报告，exit 0' {
    $r = Invoke-Cli -CliArgs @('audit', $redFixture) -Name 'audit-default'
    Assert-Equal $r.Code 0 'exit code'
    $j = Get-CliJson -Result $r -Name 'audit-default'
    Assert-Equal $j.data.strict $false 'strict'
    Assert-True ($j.data.redCount -gt 0) '样本应含红牌'
  }

  Run-Case 'audit --strict：红牌 exit 3，passed=false' {
    $r = Invoke-Cli -CliArgs @('audit', '--strict', $redFixture) -Name 'audit-strict'
    Assert-Equal $r.Code 3 'exit code'
    $j = Get-CliJson -Result $r -Name 'audit-strict'
    Assert-Equal $j.data.strict $true 'strict'
    Assert-Equal $j.data.passed $false 'passed'
    Assert-True ($j.data.redCount -gt 0) '样本应含红牌'
  }

  Run-Case '未知命令：exit 2，ok=false' {
    $r = Invoke-Cli -CliArgs @('no-such-command') -Name 'unknown'
    Assert-Equal $r.Code 2 'exit code'
    $j = Get-CliJson -Result $r -Name 'unknown'
    Assert-Equal $j.ok $false 'ok'
    Assert-True ($j.error -match '未知命令') '错误信息'
  }

  Run-Case 'render 失败：顶层 ok=false，exit 1' {
    $blocked = Join-Path $tmp 'blocked-parent'
    [IO.File]::WriteAllText($blocked, 'x', $utf8NoBom)
    $outBase = Join-Path $blocked 'out'
    $r = Invoke-Cli -CliArgs @('render', '--in', $fixture, '--out', $outBase) -Name 'render-fail'
    Assert-Equal $r.Code 1 'exit code'
    $j = Get-CliJson -Result $r -Name 'render-fail'
    Assert-Equal $j.ok $false '顶层 ok'
    Assert-Equal $j.data.ok $false 'data.ok'
    Assert-True ([string]::IsNullOrWhiteSpace($j.error) -eq $false) '顶层 error 为空'
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
  Write-Host ''
  Write-Host ("FAILED: {0} case(s)" -f $script:failures) -ForegroundColor Red
  exit 1
}
Write-Host ''
Write-Host 'ALL CLI CONTRACT CHECKS PASSED' -ForegroundColor Green
exit 0
