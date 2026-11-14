param([int]$Port=7187)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$server=Join-Path $root 'server/NovelServer.exe'
$reader=Join-Path $root 'client/novel_reader.exe'
$data=Join-Path $root 'server/data'
$profile=Join-Path $root 'profile'
$base="http://127.0.0.1:$Port"
$listener=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if($listener){
 foreach($link in $listener){if((Get-Process -Id $link.OwningProcess).Path -ne $server){throw "Port $Port is occupied by another program."}}
}else{
 $env:NOVEL_DATA=$data
 Remove-Item Env:NOVEL_TOKEN -ErrorAction SilentlyContinue
 $env:ASPNETCORE_URLS=$base
 $svc=Start-Process -FilePath $server -WorkingDirectory (Split-Path $server) -WindowStyle Hidden -PassThru
}
for($i=0;$i -lt 45;$i++){try{if((Invoke-RestMethod "$base/health" -TimeoutSec 1).version -eq 2){break}}catch{};Start-Sleep -Milliseconds 200}
if((Invoke-RestMethod "$base/health" -TimeoutSec 2).version -ne 2){throw "Cannot connect to reader service."}
$token=[IO.File]::ReadAllText((Join-Path $data 'access-token.txt')).Trim()
$env:NOVEL_PROFILE=$profile
New-Item -ItemType Directory -Path $profile -Force|Out-Null
$f=Join-Path $profile 'profile.json'
if(!(Test-Path $f)){[IO.File]::WriteAllText($f,(@{base=$base;token=$token}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Start-Process -FilePath $reader -WorkingDirectory (Split-Path $reader)
