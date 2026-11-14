$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$exe=Join-Path $root 'release/v2-windows-x64/server/NovelServer.exe'
$env:NOVEL_DATA=Join-Path $PSScriptRoot ('work/v2-online-'+[guid]::NewGuid().ToString('N'))
$env:NOVEL_TOKEN=[guid]::NewGuid().ToString('N')
$env:ASPNETCORE_URLS='http://127.0.0.1:17953'
$h=@{Authorization="Bearer $env:NOVEL_TOKEN"}
function GetApi([string]$route){Invoke-RestMethod "$env:ASPNETCORE_URLS/api/$route" -Headers $h -TimeoutSec 120}
if(Get-NetTCPConnection -LocalPort 17953 -State Listen -ErrorAction SilentlyContinue){throw 'QA port occupied'}
$p=Start-Process $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
try{
 for($i=0;$i -lt 40;$i++){try{if((Invoke-RestMethod "$env:ASPNETCORE_URLS/health").version -eq 2){break}}catch{};Start-Sleep -Milliseconds 250}
 $report=@()
 foreach($source in (GetApi sources)){
 $q=if($source.name -like '*疯读*'){'绝世剑神'}else{'绝代双骄'}
 $row=[ordered]@{source=$source.name;query=$q;date=(Get-Date -Format o);passed=$false}
 try{
 $hits=GetApi "search?source=$($source.id)&q=$([uri]::EscapeDataString($q))"
 $b=if($source.name -like '*疯读*'){$hits|Where-Object title -eq $q|Select-Object -First 1}else{$hits|Where-Object {$_.url -match '/wuxia/|/book/|/gulong/'}|Select-Object -First 1}
 if(!$b){throw '未找到候选书籍'}
 $toc=GetApi "books/$($b.id)/toc";if($toc.Count -lt 3){throw '目录不足三章'}
 $row.title=$b.title;$row.tocCount=$toc.Count;$row.url=$b.url;$row.chapters=@()
 foreach($c in $toc[0..2]){$data=GetApi "books/$($b.id)/chapters/$($c.id)";$text=$data.blocks.text -join '';if($text.Length -lt 100){throw "章节正文过短 $($c.title)"};$row.chapters+=@{title=$c.title;characters=$text.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))}}
 if(($row.chapters.sha256|Sort-Object -Unique).Count -ne 3){throw '三章正文重复'};$row.passed=$true
 }catch{$row.error=$_.Exception.Message}
 $report+=[pscustomobject]$row
 }
 $report|ConvertTo-Json -Depth 5|Set-Content "$PSScriptRoot/v2-online-results.json" -Encoding utf8
 $report|Select-Object source,passed,error
}finally{if(!$p.HasExited){$p.Kill();$p.WaitForExit()}}
