"""Only on first run, seed a separate v2 service with an online SQLite backup of v1."""
import sqlite3, pathlib, shutil, uuid
root=pathlib.Path(__file__).resolve().parents[1]
source=root/'release/windows-x64/server/data'
server=root/'release/v2-windows-x64/server'
dest=server/'data'
if dest.exists(): print('Existing v2 library retained')
elif (source/'library.sqlite').exists():
    staging=server/('migration-'+uuid.uuid4().hex)
    staging.mkdir()
    with sqlite3.connect((source/'library.sqlite').as_uri()+'?mode=ro',uri=True) as db,sqlite3.connect(staging/'library.sqlite') as out:
        db.backup(out)
    db.close();out.close()
    shutil.copytree(source/'originals',staging/'originals')
    if (source/'access-token.txt').exists():shutil.copy2(source/'access-token.txt',staging/'access-token.txt')
    staging.rename(dest)
    print('Created separate v2 library; v1 unchanged.')
