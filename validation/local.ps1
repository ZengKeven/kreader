param([string]$ServerExe,[int]$Port=17387)
$ErrorActionPreference='Stop'
$work=Join-Path $PSScriptRoot ('work/local-'+[guid]::NewGuid().ToString('N'))
& "$PSScriptRoot/fixtures.ps1" -Folder $work
$env:NOVEL_DATA=Join-Path $work 'data';$env:NOVEL_TOKEN=[guid]::NewGuid().ToString('N');$env:ASPNETCORE_URLS="http://127.0.0.1:$Port"
$base=$env:ASPNETCORE_URLS+'/api';$headers=@{Authorization='Bearer '+$env:NOVEL_TOKEN}
$checks=[Collections.Generic.List[string]]::new()
function Check($ok,$name){if(!$ok){throw "验收失败：$name"};$checks.Add($name)}
function StartServer{
 $p=Start-Process -FilePath $ServerExe -WorkingDirectory (Split-Path $ServerExe) -WindowStyle Hidden -PassThru
 for($i=0;$i -lt 60;$i++){try{Invoke-RestMethod "$env:ASPNETCORE_URLS/health"|Out-Null;return $p}catch{Start-Sleep -Milliseconds 250}}
 throw '服务未启动'
}
function GetApi($route){Invoke-RestMethod "$base/$route" -Headers $headers}
function WriteApi($route,$body){Invoke-RestMethod "$base/$route" -Headers $headers -Method Put -ContentType 'application/json; charset=utf-8' -Body ($body|ConvertTo-Json -Compress)}
function Upload($file){Invoke-RestMethod "$base/upload" -Method Post -Headers $headers -Form @{file=(Get-Item $file);encoding='auto'}}
$p=StartServer
try{
 $unauth=Invoke-WebRequest "$base/library" -SkipHttpErrorCheck;Check ($unauth.StatusCode -eq 401) '个人令牌鉴权'
 $t=Upload "$work/山路.txt";$tc=GetApi "books/$($t.id)/toc";Check ($tc.Count -eq 34) 'GB18030 自动识别与 34 章分章'
 $e=Upload "$work/灯塔.epub";$c=GetApi "books/$($e.id)/toc";Check ($c.Count -eq 2 -and $c[1].title -eq '归航') 'EPUB spine 与同一 XHTML 内目录锚点'
 $text=GetApi "books/$($e.id)/chapters/$($c[0].id)"
 Check (($text.blocks.markup -join '') -match '<strong>第一盏灯</strong>' -and ($text.blocks.markup -join '') -match '<em>') 'EPUB 加粗与斜体'
 $im=$text.blocks|Where-Object kind -eq image;$asset=Invoke-WebRequest "$base/books/$($e.id)/assets/$($im.image)" -Headers $headers
 Check ($asset.StatusCode -eq 200 -and $asset.Headers.'Content-Type' -contains 'image/png') '插图按书籍获取'
 $spot=@{chapterId=$c[0].id;paragraph=4;offset=5;quote='';version=0;eventId=[guid]::NewGuid().ToString()}
 $accepted=WriteApi "books/$($e.id)/progress" $spot
 Check ($accepted.version -eq 1) '设备 A 保存段内位置'
 $retry=WriteApi "books/$($e.id)/progress" $spot;Check ($retry.version -eq 1) '同一事件重试幂等'
 $stale=$spot.Clone();$stale.eventId=[guid]::NewGuid().ToString()
 $res=Invoke-WebRequest "$base/books/$($e.id)/progress" -Headers $headers -Method Put -ContentType 'application/json' -Body ($stale|ConvertTo-Json) -SkipHttpErrorCheck
 Check ($res.StatusCode -eq 409) '设备 B 旧版本冲突保护'
 $dupe=Upload "$work/灯塔.epub";Check ($dupe.id -eq $e.id -and (GetApi "books/$($dupe.id)/progress").offset -eq 5) '重复上传保留进度'
 $p.Kill();$p.WaitForExit();$p=StartServer
 Check ((GetApi 'library').shelf.Count -eq 2 -and (GetApi 'library').history.Count -eq 1) '重启服务后书架与历史持续存在'
 Check ((GetApi "books/$($e.id)/progress").paragraph -eq 4 -and (GetApi "books/$($e.id)/chapters/$($c[1].id)").title -eq '归航') '第二客户端重读与续读'
 $spot.eventId=[guid]::NewGuid().ToString();$spot.version=1;$spot.paragraph=1;$spot.offset=0
 Check ((WriteApi "books/$($e.id)/progress" $spot).paragraph -eq 1) '主动回读前段'
 WriteApi "books/$($e.id)/shelf" @{shelf=$false}|Out-Null
 Check ((GetApi 'library').shelf.Count -eq 1 -and (GetApi 'library').history.Count -eq 1) '移出书架保留历史'
 Invoke-RestMethod "$base/books/$($e.id)" -Headers $headers -Method Delete|Out-Null
 Check ((GetApi 'library').history.Count -eq 0 -and !(Test-Path "$work/data/originals/$($e.id).epub")) '删除原书和关联记录'
 [pscustomobject]@{date=(Get-Date -Format o);passed=$checks}|ConvertTo-Json -Depth 4|Set-Content "$PSScriptRoot/local-results.json"
 $checks
}finally{if(!$p.HasExited){$p.Kill();$p.WaitForExit()}}
