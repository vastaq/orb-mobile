"""Host-only adjudication for household-april. Usage: score.py RUN_ROOT_OR_SNAPSHOT."""
import csv
import hashlib
import io
import json
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

EXPECTED = {
    '餐食': ('46.25', '3.20', '43.05'),
    '出行': ('16.50', '2.00', '14.50'),
    '日用': ('46.80', '0', '46.80'),
    '订阅': ('0', '9.99', '-9.99'),
    '学习': ('21.30', '0', '21.30'),
}
TOTAL = ('130.85', '15.19', '115.66')
ORIGINAL = {
    'project/categories.csv': '47c74cb7553476a4bf5b014ebe718e83c843a5b39287ce2db6ab183e4ae71862',
    'project/ledger.csv': '2be52e3e73dc60943ebacd20531d66d38d783cb8f0d9150a276965d3aff7d5d1',
}
def read(root):
    paths = [*ORIGINAL, 'project/month-summary.csv']
    if root.is_dir():
        return {name:(root/name).read_bytes() for name in paths
                if not (root/name).is_symlink() and (root/name).is_file()}
    snapshot = json.loads(root.read_text(encoding='utf8'))
    files = snapshot.get('files', snapshot)
    return {name:files[name].encode('utf8') for name in paths if isinstance(files.get(name), str)}

def adjudicate(files):
    c = {'originals':all(hashlib.sha256(files.get(name,b'')).hexdigest()==sha for name,sha in ORIGINAL.items()),
         'saved': 'project/month-summary.csv' in files, 'header':False,'categories':False,
         'amounts':False,'last_row_total':False}
    try:
        rows = list(csv.reader(io.StringIO(files['project/month-summary.csv'].decode('utf-8-sig'),newline=''),strict=True))
        while rows and not rows[-1]:
            rows.pop()
        c['header'] = rows[0] == ['分类','支出','退款','净支出']
        categories = rows[1:-1]
        c['categories'] = len(categories)==len(EXPECTED) and {r[0] for r in categories}==set(EXPECTED)
        def same(actual, gold):
            return len(actual)==len(gold) and all(Decimal(v.strip()).is_finite() and Decimal(v.strip())==Decimal(w)
                                                 for v,w in zip(actual,gold))
        c['last_row_total'] = rows[-1][0]=='合计' and same(rows[-1][1:], TOTAL)
        c['amounts'] = c['categories'] and all(same(row[1:],EXPECTED[row[0]]) for row in categories)
    except (UnicodeError, csv.Error, InvalidOperation, KeyError, IndexError, ValueError):
        pass
    return {'id':'household-april','passed':all(c.values()),'checks':c}

if __name__ == '__main__':
    print(json.dumps(adjudicate(read(Path(sys.argv[1]))),ensure_ascii=False))
