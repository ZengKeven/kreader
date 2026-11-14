$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$env:COVER_QA=Get-Content -LiteralPath "$PSScriptRoot/work/cover-session.json" -Encoding utf8 -Raw
$run=$env:COVER_QA|ConvertFrom-Json
$env:NOVEL_DATA=Join-Path $run.folder 'server'
$env:ASPNETCORE_URLS='http://127.0.0.1:17955'
Remove-Item Env:NOVEL_TOKEN -ErrorAction SilentlyContinue
$env:COVER_SCREENSHOT=Join-Path $PSScriptRoot 'cover-shelf.png'
$exe=Join-Path $PSScriptRoot 'work/cover-release/server/NovelServer.exe'
if(Get-NetTCPConnection -LocalPort 17955 -State Listen -ErrorAction SilentlyContinue){throw '测试端口已占用'}
$svc=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru -WindowStyle Hidden
try{
  for($i=0;$i -lt 40;$i++){try{Invoke-RestMethod "$env:ASPNETCORE_URLS/health"|Out-Null;break}catch{Start-Sleep -Milliseconds 250}}
  $auth=@{Authorization='Bearer '+[IO.File]::ReadAllText("$env:NOVEL_DATA/access-token.txt").Trim()}
  $shelf=(Invoke-RestMethod "$env:ASPNETCORE_URLS/api/library" -Headers $auth).shelf
  foreach($b in $shelf){if ($b.id -notin @($run.online,$run.epub,$run.txt)){Invoke-RestMethod "$env:ASPNETCORE_URLS/api/books/$($b.id)/shelf" -Method Put -Headers $auth -ContentType 'application/json' -Body '{"shelf":false}'|Out-Null}}
  & "$PSScriptRoot/build-v2.ps1" -Task integration -IntegrationTest 'integration_test/book_cover_test.dart'
}finally{if(!$svc.HasExited){$svc.Kill();$svc.WaitForExit()}}
