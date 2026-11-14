$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$dir=Join-Path $PSScriptRoot ('work/v2-native-'+[guid]::NewGuid().ToString('N'))
& "$PSScriptRoot/fixtures.ps1" -Folder $dir -ThreeChapters
$env:NOVEL_DATA=Join-Path $dir server
$env:NOVEL_TEST_WORK=$dir
$env:NOVEL_SCREENSHOTS=Join-Path $PSScriptRoot 'v2-screens'
New-Item -ItemType Directory -Path $env:NOVEL_SCREENSHOTS -Force|Out-Null
$env:ASPNETCORE_URLS="http://127.0.0.1:17948"
$env:NOVEL_TEST_URL=$env:ASPNETCORE_URLS
Remove-Item Env:NOVEL_TOKEN -ErrorAction SilentlyContinue
$exe=Join-Path $root 'release/v2-windows-x64/server/NovelServer.exe'
if(Get-NetTCPConnection -LocalPort 17948 -State Listen -ErrorAction SilentlyContinue){throw 'QA port occupied'}
$svc=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
try{
 for($i=0;$i -lt 40;$i++){try{$h=Invoke-RestMethod "$env:NOVEL_TEST_URL/health";if($h.version -eq 2){break}}catch{};Start-Sleep -Milliseconds 250}
 & "$PSScriptRoot/build-v2.ps1" -Task integration
}finally{if(!$svc.HasExited){$svc.Kill();$svc.WaitForExit()}}
