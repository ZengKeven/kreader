#requires -Version 7.0
param(
    [string]$CollectionPath = (Join-Path $PSScriptRoot 'yck-novel.json'),
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$revision = 'b148fe2072b290f4a207ee0846874ea19e6dacc7'
$url = "https://raw.githubusercontent.com/liufuyou/read/$revision/sources/yck-novel.json"
$expectedHash = '655E94086167D82F837245FFEC74B8E0EFEBB3AC1641DA421AF6B70D10917ECB'
if (!(Test-Path -LiteralPath $CollectionPath)) {
    $temp = "$CollectionPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Invoke-WebRequest -Uri $url -OutFile $temp
        if ((Get-FileHash -LiteralPath $temp).Hash -ne $expectedHash) { throw '书源合集校验失败' }
        Move-Item -LiteralPath $temp -Destination $CollectionPath
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    }
}
if ((Get-FileHash -LiteralPath $CollectionPath).Hash -ne $expectedHash) { throw '现有合集与项目验证版本不同，请另选 CollectionPath' }
$catalog = Get-Content -LiteralPath $CollectionPath -Raw -Encoding utf8 | ConvertFrom-Json
$sources = foreach ($name in '疯读小说（优+）','古龙武侠（优+）') {
    $matchesByName = @($catalog | Where-Object bookSourceName -CEQ $name)
    if ($matchesByName.Count -ne 1) { throw "未找到唯一的书源 $name" }
    $matchesByName[0]
}
ConvertTo-Json -InputObject @($sources) -Depth 64 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Output "已准备 $($sources.Count) 个在线测试书源"
