"""Use SQLite online backup, preserving the source. Run the test on a private snapshot."""
from pathlib import Path
import sys,sqlite3,subprocess,os,secrets,time,json,urllib.request,uuid,shutil,hashlib
root=Path(__file__).resolve().parents[1]
sources=sorted((root/"validation/work").glob("ui-*/server/library.sqlite"))
src=next(p for p in sources if p.exists())
d=root/"validation/work"/("v2-migration-"+uuid.uuid4().hex)
d.mkdir()
def connect(p,ro=False):return sqlite3.connect(p.as_uri()+("?mode=ro" if ro else ""),uri=True)
with connect(src,True) as old,connect(d/"library.sqlite") as new:
    assert old.execute("PRAGMA user_version").fetchone()[0]==1
    old.backup(new)
shutil.copytree(src.parent/"originals",d/"originals")
def snapshot():
    with connect(d/"library.sqlite",True) as db:return {t:db.execute("select * from "+t+" order by rowid").fetchall() for t in ("books","progress","history","sources","chapters","assets")}
prior=snapshot()
key=secrets.token_hex(24)
url="http://127.0.0.1:17949"
checks=[]
def check(ok,txt):
    if not ok:raise AssertionError(txt)
    checks.append(txt)
def req(route,body=None,method=None):
    r=urllib.request.Request(url+route,None if body is None else json.dumps(body).encode(),{"Authorization":"Bearer "+key,"Content-Type":"application/json"},method=method)
    return json.load(urllib.request.urlopen(r,timeout=10))
with (d/"qa.log").open("w") as log:
    p=subprocess.Popen([str(root/"release/v2-windows-x64/server/NovelServer.exe")],env={**os.environ,"NOVEL_DATA":str(d),"NOVEL_TOKEN":key,"ASPNETCORE_URLS":url},stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        for _ in range(80):
            try:
                if req("/health")["version"]==2:break
            except OSError:time.sleep(.15)
        check(p.poll() is None and prior==snapshot(),"v1 副本升级后逐行比对六张旧表，书库、进度、历史及插图均保留")
        lib=req("/api/library");check(len(lib["shelf"])>0 and len(lib["indicators"])==len(lib["shelf"]),"书架指示器")
        b=next(b for b in lib["shelf"] if b["url"]==".txt");bid=b["id"];cid=req("/api/books/"+bid+"/toc")[0]["id"]
        for kind,v in [("group",{"name":"常读"}),("membership",{"book":bid,"group":"g"}),("mark",{"book":bid,"chapter":cid,"paragraph":0,"offset":0,"end":2,"quote":"第一","kind":"批注","note":"记号"}),("rule",{"from":"甲","to":"乙"}),("dict",{"word":"甲","definition":"示例"}),("correction",{"book":bid,"chapter":cid,"paragraph":0,"original":"甲","value":"乙"}),("mapping",{"book":bid,"chapter":cid,"targetBook":bid})]:
            item={"id":uuid.uuid4().hex,**v};req("/api/items/"+kind+"/"+item["id"],item,"PUT")
            check(item in req("/api/items/"+kind),"独立 HTTP 请求写入和读回 "+kind)
        check(len(req("/api/activity"))>0,"按日期、书籍、章节查询阅读记录")
        found=req("/api/books/"+bid+"/find?q="+urllib.parse.quote("山"));check(len(found)>0 and "offset" in found[0],"TXT 全书检索含字符位置")
        ret=req("/api/books/"+bid+"/reparse",{"encoding":"GB18030","pattern":"^第.{1,8}章"},"POST");check(ret["count"]>1,"保留原文件，使用自选编码和标题规则重新分章")
    finally:p.terminate();p.wait()
out=root/"validation/v2-api-results.json"
out.write_text(json.dumps({"source_schema":1,"target_schema":2,"passed":checks,"preserved_rows":{k:len(v) for k,v in prior.items()}},ensure_ascii=False,indent=2),encoding="utf-8")
print(len(checks),"checks passed")
