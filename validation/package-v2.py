from pathlib import Path
import hashlib,zipfile
root=Path(__file__).resolve().parents[1]
bundle=root/'release/v2-windows-x64'
target=root/'release/NovelReader-2.0.1-windows-x64.zip'
stage=target.with_suffix('.zip.new')
files=[p for p in bundle.rglob('*') if p.is_file() and not p.relative_to(bundle).as_posix().startswith(('profile/','server/data/'))]
for p in files:
    assert p.suffix.lower() not in ('.sqlite','.db','.epub','.tmp') and p.name not in ('access-token.txt','profile.json','profile.json.old'),p
with zipfile.ZipFile(stage,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=5) as z:
    for p in files:z.write(p,p.relative_to(bundle).as_posix())
with zipfile.ZipFile(stage) as z:
    assert z.testzip() is None
    names=set(z.namelist())
    assert 'client/data/flutter_assets/assets/cover-landscape.jpg' in names
    assert {'client/novel_reader.exe','server/NovelServer.exe','server/coreclr.dll','client/flutter_windows.dll','client/data/app.so','client/data/flutter_assets/assets/han.json','Start-Reader.cmd','Start-Reader.ps1'} <=names
stage.replace(target)
h=hashlib.file_digest(target.open('rb'),'sha256').hexdigest()
target.with_suffix('.zip.sha256').write_text(h+'  '+target.name+'\n',encoding='ascii')
print(target.name,target.stat().st_size,h)
