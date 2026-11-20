import json,re,sys,pathlib
suite=pathlib.Path(__file__).resolve().parents[1]; task=json.loads((suite/'public/public.json').read_text())[0]; expected=json.loads((suite/'private/expected.json').read_text())
p=pathlib.Path(sys.argv[1])
if p.is_dir():
    def read(name):
        f=p/name
        if f.is_symlink() or not f.is_file() or f.stat().st_size>1048576: return None
        return f.read_bytes().decode('utf8')
else:
    blob=json.loads(p.read_text()); files=blob.get('files',blob);read=files.get
checks={'inputs_intact':all(read(k)==v for k,v in task['files'].items())}
text=read('project/differences.tsv') or ''
rows=text.removeprefix('\ufeff').splitlines()
checks['tsv_header']=bool(rows) and rows[0].split('\t')==['sku','ordered','received','delta']
data=[]
for row in rows[1:]:
    fields=row.split('\t')
    if len(fields)!=4 or any(not re.fullmatch(r'[+-]?\d+',s) for s in fields[1:]): data.append([None]);continue
    data.append([fields[0],*map(int,fields[1:])])
checks['exact_skus_in_order']=[v[0] for v in data]==[v[0] for v in expected]
checks['counts_and_deltas']=sorted(data,key=lambda r:str(r[0]))==expected
print(json.dumps({'passed':all(checks.values()),'checks':checks}))
