"""Generate the offline reader's character tables using Windows NLS."""
import ctypes, json, pathlib
convert = ctypes.windll.kernel32.LCMapStringEx
root = pathlib.Path(__file__).resolve().parents[1] / "client/assets"
root.mkdir(exist_ok=True)
data = {}
for name, flag in (("简体",0x02000000),("繁体",0x04000000)):
    result = {}
    for cp in range(0x3400, 0xa000):
        ch=chr(cp)
        buf=ctypes.create_unicode_buffer(8)
        n=convert("zh-CN",flag,ch,1,buf,8,None,None,0)
        if n and buf.value and buf.value!=ch:
            result[ch]=buf.value
    data[name]=result
(root/"han.json").write_text(json.dumps(data,ensure_ascii=False,separators=(",",":")),encoding="utf-8")
print({k:len(v) for k,v in data.items()})
