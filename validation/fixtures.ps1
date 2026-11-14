param([Parameter(Mandatory)][string]$Folder,[switch]$ThreeChapters)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $Folder|Out-Null
$txt=(1..34|ForEach-Object {"第$_"+"章 山路"+[Environment]::NewLine+('清晨，河岸上的雾渐渐散去。我们沿着石阶往上走，看见远处山谷间的一片竹林。'*20)}) -join [Environment]::NewLine
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
[IO.File]::WriteAllBytes((Join-Path $Folder '山路.txt'),[Text.Encoding]::GetEncoding('GB18030').GetBytes($txt))
$path=Join-Path $Folder '灯塔.epub'
if(Test-Path $path){throw "样本目录需为空：$path"}
$zip=[IO.Compression.ZipFile]::Open($path,'Create')
try{
 function AddText($name,$xml){if($ThreeChapters -and $name -like '*nav.xhtml'){$xml=$xml.Replace('</nav>','<a href="third.xhtml">海港</a></nav>')};if($ThreeChapters -and $name -like '*.opf'){ $xml=$xml.Replace('</manifest>','<item id="third" href="third.xhtml" media-type="application/xhtml+xml"/></manifest>').Replace('</spine>','<itemref idref="third"/></spine>')};$entry=$zip.CreateEntry($name);$out=$entry.Open();try{$data=[Text.Encoding]::UTF8.GetBytes($xml);$out.Write($data,0,$data.Length)}finally{$out.Dispose()}}
 AddText 'mimetype' 'application/epub+zip'
 AddText 'META-INF/container.xml' '<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>'
 AddText 'OEBPS/book.opf' '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:d="http://purl.org/dc/elements/1.1/"><d:title>灯塔手记</d:title><d:creator>测试作者</d:creator></metadata><manifest><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/><item id="ill" href="light.png" media-type="image/png"/></manifest><spine><itemref idref="body"/></spine></package>'
 AddText 'OEBPS/nav.xhtml' '<html xmlns="http://www.w3.org/1999/xhtml"><body><nav><a href="body.xhtml#one">潮声</a><a href="body.xhtml#two">归航</a></nav></body></html>'
 $paragraphs=(1..90|ForEach-Object {"<p>第 $_ 段。海风吹过灯塔的栏杆，守灯人在雾里听见了远处传来的汽笛声。<em>此刻天色微明。</em></p>"}) -join ''
 AddText 'OEBPS/body.xhtml' ('<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="one">潮声</h1><p>夜雾里亮起了<strong>第一盏灯</strong>。</p><img src="light.png" alt="灯塔插图"/>'+$paragraphs+'<h1 id="two">归航</h1><p>第二天，帆船沿着旧航道回来了。</p></body></html>')
 if($ThreeChapters){ AddText 'OEBPS/third.xhtml' '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>海港</h1><p>第三天，守灯人回到海港。</p></body></html>' }
 $entry=$zip.CreateEntry('OEBPS/light.png');$out=$entry.Open();try{$bytes=[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');$out.Write($bytes,0,$bytes.Length)}finally{$out.Dispose()}
}finally{$zip.Dispose()}
