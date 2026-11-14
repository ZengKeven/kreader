param([string]$ServerExe,[int]$Port=17386)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$env:NOVEL_DATA=Join-Path $root ('work/probe-'+[guid]::NewGuid().ToString('N'))
$env:NOVEL_TOKEN=[guid]::NewGuid().ToString('N')
$env:ASPNETCORE_URLS="http://127.0.0.1:$Port"
$base=$env:ASPNETCORE_URLS
$headers=@{Authorization="Bearer "+$env:NOVEL_TOKEN}
$process=Start-Process -FilePath $ServerExe -WorkingDirectory (Split-Path $ServerExe) -WindowStyle Hidden -PassThru
try{
 for($i=0;$i -lt 60;$i++){try{Invoke-RestMethod "$base/health" | Out-Null;break}catch{Start-Sleep -Milliseconds 300}}
 $json=Get-Content -Raw -Encoding utf8 "$root/yck-novel.json"
 $report=Invoke-RestMethod "$base/api/sources/import" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{json=$json}|ConvertTo-Json -Compress)
 $report|ConvertTo-Json -Depth 4|Set-Content -Encoding utf8 "$root/source-diagnostics.json"
 $sources=@(Invoke-RestMethod "$base/api/sources" -Headers $headers | Write-Output)
 $candidates=@(
 @('古龙武侠','绝代双骄'),@('轻之文库','幻想'),@('国学書库','西游'),@('疯读小说','剑'),@('金庸小说','雪山'),@('篱笆文学','剑'),@('得奇小说','传说'),@('中华典藏','论语'),@('天天书吧','剑来'),@('有度轻说','剑'),@('八零小说','仙'),@('轻之文库','魔法'),@('全本小说','剑'),@('铅笔小说','剑'),@('零零小说','仙'),@('古龙武侠','小李飞刀'),@('天涯知识','三国'),@('百合爱会','江湖'),@('爱下电子','斗罗'),@('无线电子','剑来'),@('天籁小说','仙'),@('霹雳书坊','无限'),@('乐文阁网','剑'),@('速读谷','传说'),@('就爱文学','斗破'),@('古诗文网','李白'))
 $results=[Collections.Generic.List[object]]::new()
 foreach($pair in $candidates){
  $source=$sources | Where-Object { $_.name.StartsWith($pair[0]) -and !$_.issue } | Select-Object -First 1
  if(!$source){continue}
  $stage='搜索';$row=[ordered]@{source=$source.name;id=$source.id;query=$pair[1];date=(Get-Date -Format o);passed=$false}
  try{
   $hits=Invoke-RestMethod "$base/api/search?source=$($source.id)&q=$([uri]::EscapeDataString($pair[1]))" -Headers $headers -TimeoutSec 35
   if(!$hits.Count){throw '零条结果'}
   $book=if($source.name.StartsWith('古龙武侠')){ $hits | Where-Object { $_.url -match '/wuxia/|/book/|/gulong/' } | Select-Object -First 1 }else{ $hits[0] };if(!$book){throw '未找到小说类匹配条目'};$row.title=$book.title;$row.url=$book.url;$stage='详情及目录'
   $toc=Invoke-RestMethod "$base/api/books/$($book.id)/toc" -Headers $headers -TimeoutSec 130
   if($toc.Count -lt 2){throw '目录少于两章'}
   $resolvedBook=Invoke-RestMethod "$base/api/books/$($book.id)" -Headers $headers;$row.detailTitle=$resolvedBook.title;$row.chapterCount=$toc.Count;$row.samples=@()
   foreach($ch in ($toc | Select-Object -First 2)){
    $stage='正文 '+$ch.title
    $c=Invoke-RestMethod "$base/api/books/$($book.id)/chapters/$($ch.id)" -Headers $headers -TimeoutSec 65
    $body=($c.blocks.text -join '');if($body.Length -lt 100 -or $body -notmatch '[\u3400-\u9fff]{3}' -or $body -match '访问过于频繁|请完成验证|本章仅供预览'){throw '正文过短、提示页或不可读'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)))
    $row.samples+=@(@{chapter=$ch.title;chars=$body.Length;sha256=$hash;excerpt=$body.Substring(0,[Math]::Min(28,$body.Length))})
   }
   if($row.samples[0].sha256 -eq $row.samples[1].sha256){throw '两章内容重复'}
   $row.passed=$true
  }catch{$row.failure=$_.Exception.Message;if($_.ErrorDetails.Message){$row.detail=$_.ErrorDetails.Message};$row.stage=$stage}
  $results.Add([pscustomobject]$row)
  $results|ConvertTo-Json -AsArray -Depth 6|Set-Content -Encoding utf8 "$root/online-results.json"
  if(@($results|Where-Object passed).Count -ge 2){break}
 }
}finally{if(!$process.HasExited){$process.Kill();$process.WaitForExit()}}
