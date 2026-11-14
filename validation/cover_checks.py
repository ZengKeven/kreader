"""Exercise the production cover route on an isolated copy of the v2 book database."""
from pathlib import Path
import hashlib, http.client, json, os, shutil, sqlite3, subprocess, time, uuid, zipfile
from urllib.parse import urlsplit
from concurrent.futures import ThreadPoolExecutor
from PIL import Image,ImageDraw
from io import BytesIO
root=Path(__file__).resolve().parents[1]
work=root/'validation/work'/('covers-'+uuid.uuid4().hex)
data=work/'server'
data.mkdir(parents=True)
old=root/'release/v2-windows-x64/server/data'
with sqlite3.connect((old/'library.sqlite').as_uri()+'?mode=ro',uri=True) as source,sqlite3.connect(data/'library.sqlite') as target: source.backup(target)
source.close(); target.close()
shutil.copytree(old/'originals',data/'originals')
port=17955
server=root/'validation/work/cover-release/server/NovelServer.exe'
service=subprocess.Popen([str(server)],env={**os.environ,'NOVEL_DATA':str(data),'ASPNETCORE_URLS':'http://127.0.0.1:'+str(port),'NOVEL_TOKEN':''},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
def request(route,method='GET',body=None,headers=None):
    h=http.client.HTTPConnection('127.0.0.1',port,timeout=65)
    try:
        h.request(method,route,body,{'Authorization':'Bearer '+token,**(headers or {})})
        r=h.getresponse();return r.status,r.getheader('Content-Type',''),r.read()
    finally:h.close()
def upload(path):
    boundary=uuid.uuid4().hex
    body=(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{path.name}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()+path.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
    status,_,res=request('/api/upload','POST',body,{'Content-Type':'multipart/form-data; boundary='+boundary})
    assert status==200, (status,res[:200]);return json.loads(res)['id']
def image_resource(id):return request('/api/books/'+id+'/cover')
token=''
results={}
try:
    for _ in range(60):
        try:
            if request('/health')[0]==200:break
        except OSError:time.sleep(.2)
    token=(data/'access-token.txt').read_text().strip()
    with sqlite3.connect(data/'library.sqlite') as db:
        old_book=db.execute("SELECT Id,Url FROM books WHERE Url='https://book.qq.com/book-detail/462521'").fetchone()
        if not old_book:
            bid='a'*32
            db.execute("INSERT INTO books VALUES(?,?,?,?,?,?,?,1,0)",(bid,'完美世界','辰东','test-penguin','https://book.qq.com/book-detail/462521','',''))
        else:bid=old_book[0]
        db.execute("DELETE FROM covers WHERE BookId=?",(bid,))
        db.execute("UPDATE books SET Cover='' WHERE Id=?",(bid,))
        pos=db.execute("SELECT * FROM progress WHERE BookId=?",(bid,)).fetchall()
    with ThreadPoolExecutor(2) as pool: online=list(pool.map(image_resource,[bid,bid]))
    code,mime,pixels=online[0]
    assert code==200 and mime.startswith('image/') and pixels==online[1][2], (code,mime)
    im=Image.open(BytesIO(pixels)); im.load()
    assert im.width>35 and im.height>40
    with sqlite3.connect(data/'library.sqlite') as db:
        newurl=db.execute("SELECT Cover FROM books WHERE Id=?",(bid,)).fetchone()[0]
        assert db.execute("SELECT * FROM progress WHERE BookId=?",(bid,)).fetchall()==pos
        assert db.execute("SELECT count(*) FROM covers WHERE BookId=?",(bid,)).fetchone()[0]==1
    results['online']={'title':'完美世界','width':im.width,'height':im.height,'bytes':len(pixels),'sourceHost':urlsplit(newurl).hostname}
    art=Image.new('RGB',(180,270),'#2c5772');d=ImageDraw.Draw(art);d.ellipse((60,20,120,80),fill='#fbdf88');d.polygon([(0,205),(62,108),(105,160),(134,120),(180,182),(180,270),(0,270)],fill='#75baa8');cover=BytesIO();art.save(cover,format='PNG');cover=cover.getvalue()
    fixtures={}
    for typ in ['epub3','epub2','wrapper','no-cover']:
        file=work/(typ+'.epub')
        prop=' properties="cover-image"' if typ=='epub3' else ''
        meta='<meta name="cover" content="front"/>' if typ=='epub2' else ''
        guide='<guide><reference type="cover" href="pages/title.xhtml"/></guide>' if typ=='wrapper' else ''
        with zipfile.ZipFile(file,'w') as z:
            z.writestr('META-INF/container.xml','<container><rootfile full-path="OPS/book.opf"/></container>')
            z.writestr('OPS/book.opf',f'<package><metadata><title>{typ}</title>{meta}</metadata><manifest><item id="front" href="art/picture%20one.png" media-type="image/png"{prop}/><item id="ch" href="pages/read.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine>{guide}</package>')
            z.writestr('OPS/art/picture one.png',cover)
            z.writestr('OPS/pages/title.xhtml','<html><body><svg><image href="../art/picture%20one.png"/></svg></body></html>')
            z.writestr('OPS/pages/read.xhtml','<html><body><h1>启程</h1><p>开篇。</p><img src="../art/picture%20one.png"/></body></html>')
        fid=upload(file);status,fmt,body=image_resource(fid)
        if typ=='no-cover':assert status==204
        else:assert status==200 and fmt=='image/png' and body==cover
        results[typ]=status;fixtures[typ]=fid
    file=work/'sample.txt';file.write_text('第一章 雨后\n山中清晨。',encoding='utf8');txt=upload(file);assert image_resource(txt)[0]==204
    results['txt']=204
    (root/'validation/cover-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    (root/'validation/work/cover-session.json').write_text(json.dumps({'folder':str(work),'online':bid,'epub':fixtures['epub3'],'txt':txt}),encoding='utf8')
    print('Cover API checks passed',im.size)
finally:service.terminate();service.wait()
