$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$bundle=Join-Path $root 'release/v2-windows-x64'
$dir=Join-Path $PSScriptRoot ('work/v2-smoke-'+[guid]::NewGuid().ToString('N'))
& "$PSScriptRoot/fixtures.ps1" -Folder $dir -ThreeChapters
$env:NOVEL_DATA=Join-Path $dir server
$env:ASPNETCORE_URLS='http://127.0.0.1:17951'
$clientExe="$bundle/client/novel_reader.exe"
$serverExe="$bundle/server/NovelServer.exe"
if(Get-NetTCPConnection -LocalPort 17951 -State Listen -ErrorAction SilentlyContinue){throw 'QA port occupied'}
$svc=Start-Process $serverExe -WorkingDirectory (Split-Path $serverExe) -WindowStyle Hidden -PassThru
try {
 for($i=0;$i -lt 40;$i++){try{if((Invoke-RestMethod "$env:ASPNETCORE_URLS/health").version -eq 2){break}}catch{};Start-Sleep -Milliseconds 250}
 $key=[IO.File]::ReadAllText("$env:NOVEL_DATA/access-token.txt").Trim()
 $h=@{Authorization="Bearer $key"}
 $b=Invoke-RestMethod "$env:ASPNETCORE_URLS/api/upload" -Method Post -Headers $h -Form @{file=Get-Item "$dir/灯塔.epub"}
 $toc=Invoke-RestMethod "$env:ASPNETCORE_URLS/api/books/$($b.id)/toc" -Headers $h
 if($toc.Count -ne 3){throw 'EPUB 三章检查失败'}
 $progress=@{chapterId=$toc[1].id;paragraph=1;offset=2;quote='';version=0;eventId=[guid]::NewGuid().ToString()}
 Invoke-RestMethod "$env:ASPNETCORE_URLS/api/books/$($b.id)/progress" -Method Put -Headers $h -ContentType 'application/json' -Body ($progress|ConvertTo-Json -Compress)|Out-Null
 foreach($profile in 'A','B','A'){
 $env:NOVEL_PROFILE=Join-Path $dir $profile
 if(!(Test-Path $env:NOVEL_PROFILE)){New-Item -ItemType Directory -Path $env:NOVEL_PROFILE|Out-Null;@{base=$env:ASPNETCORE_URLS;token=$key}|ConvertTo-Json|Set-Content "$env:NOVEL_PROFILE/profile.json" -Encoding utf8NoBOM}
 $app=Start-Process $clientExe -WorkingDirectory (Split-Path $clientExe) -PassThru
 try{ $ok=$false;for($i=0;$i -lt 60;$i++){Start-Sleep -Milliseconds 250;$app.Refresh();try{$state=Get-Content -Raw -Encoding UTF8 "$env:NOVEL_PROFILE/profile.json"|ConvertFrom-Json;if($app.MainWindowHandle -ne 0 -and $app.Responding -and $state.library.shelf.title -contains $b.title){$ok=$true;break}}catch{}}
 if(!$ok){throw "发布窗口未读到服务书架 $profile"}
 }finally{if(!$app.HasExited){$app.CloseMainWindow()|Out-Null;if(!$app.WaitForExit(4000)){$app.Kill();$app.WaitForExit()}}}
 }
 if((Invoke-RestMethod "$env:ASPNETCORE_URLS/api/books/$($b.id)/progress" -Headers $h).offset -ne 2){throw '打开书架改写了阅读位置'}
 @{date=(Get-Date -Format o);profiles=@('A','B','A');epubChapters=$toc.Count;originalProgressUnchanged=$true;client='Release';server='Self-contained'}|ConvertTo-Json|Set-Content "$PSScriptRoot/v2-smoke.json" -Encoding utf8
}finally{if(!$svc.HasExited){$svc.Kill();$svc.WaitForExit()}}
