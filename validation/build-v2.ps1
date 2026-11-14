param([ValidateSet('prepare','test','integration','release','analyze')][string]$Task='release',[string]$OutputDirectory,[string]$IntegrationTest='integration_test/windows_reader_test.dart')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$stage=Join-Path ([IO.Path]::GetTempPath()) 'NovelReader-v2-flutter'
New-Item -ItemType Directory -Path $stage -Force|Out-Null
foreach($name in 'lib','test','integration_test','assets','windows','android','macos'){robocopy "$root/client/$name" "$stage/$name" /E /XD ephemeral .gradle build Pods .symlinks /NFL /NDL /NJH /NJS /NP | Out-Null;if($LASTEXITCODE -gt 7){throw "copy $name"}}
Copy-Item "$root/client/pubspec.yaml","$root/client/pubspec.lock","$root/client/.metadata","$root/client/analysis_options.yaml" $stage -Force
Push-Location $stage
try {
 & flutter pub get --offline
 if($LASTEXITCODE){throw 'pub get'}
 switch($Task){
 'prepare' {return}
 'test' {& flutter test --no-pub --reporter expanded}
 'integration' {& flutter test $IntegrationTest --no-pub -d windows --reporter expanded}
 'analyze' {& flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings}
 'release' {& flutter build windows --release --no-pub}
 }
 if($LASTEXITCODE){throw "Flutter $Task failed"}
 if($Task -eq 'release'){
 $dest=if($OutputDirectory){$OutputDirectory}else{Join-Path $root 'release/v2-windows-x64/client'}
 New-Item -ItemType Directory -Path $dest -Force|Out-Null
 Copy-Item "$stage/build/windows/x64/runner/Release/*" $dest -Recurse -Force
 $crt=Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Filter 'Microsoft.VC*.CRT' -Directory -Recurse -ErrorAction SilentlyContinue|Where-Object {$_.Parent.Name -eq 'x64' -and $_.FullName -match '\\Redist\\MSVC\\'}|Sort-Object FullName -Descending|Select-Object -First 1
 if(!$crt){throw 'Visual C++ runtime not found'};Copy-Item "$($crt.FullName)/*.dll" $dest -Force
 }
}finally{Pop-Location}
