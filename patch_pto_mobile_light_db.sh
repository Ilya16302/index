#!/usr/bin/env bash
set -euo pipefail

WEBROOT="${1:-/var/www/pto}"
INDEX="$WEBROOT/index.html"
LOCALDB="$WEBROOT/localdb"
MOBILEDB="$WEBROOT/localdb_mobile"
MOBILE_LIMIT="${2:-4000}"

if [[ ! -f "$INDEX" ]]; then
  echo "Не найден $INDEX"
  exit 1
fi

if [[ ! -d "$LOCALDB" ]]; then
  echo "Не найдена папка $LOCALDB"
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cp -a "$INDEX" "$INDEX.bak.$STAMP"

mkdir -p "$MOBILEDB"

echo "[1/5] Собираю облегченную мобильную базу в $MOBILEDB (лимит строк: $MOBILE_LIMIT)..."
python3 - "$LOCALDB" "$MOBILEDB" "$MOBILE_LIMIT" <<'PY'
from pathlib import Path
import shutil, sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
limit = int(sys.argv[3])

limit_map = {
    "wb_main.csv": limit,
    "opory.csv": min(limit, 3000),
    "lr_base.csv": min(limit, 3000),
}

def trim_csv(infile: Path, outfile: Path, max_rows):
    if not infile.exists():
        return False
    if max_rows is None:
        shutil.copy2(infile, outfile)
        return True

    with infile.open("r", encoding="utf-8-sig", newline="") as f:
        lines = []
        for i, line in enumerate(f):
            lines.append(line)
            if i >= max_rows:
                break

    outfile.write_text("".join(lines), encoding="utf-8")
    return True

files = ["db.meta.json", "wb_main.csv", "opory.csv", "lr_base.csv", "welders.csv", "zra.csv"]
done = []
for name in files:
    src_file = src / name
    dst_file = dst / name
    max_rows = limit_map.get(name, None)
    if trim_csv(src_file, dst_file, max_rows):
        done.append(name)

print("Собраны файлы:", ", ".join(done))
PY

echo "[2/5] Патчу index.html под телефон..."
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

if 'function __ptoDbBasePath()' not in s:
    helper = '''
<script id="pto-mobile-db-helper">
function __ptoIsMobileDevice(){
  return /iphone|ipad|ipod|android|mobile/i.test(navigator.userAgent || "");
}
function __ptoDbBasePath(){
  return __ptoIsMobileDevice() ? "./localdb_mobile" : "./localdb";
}
</script>
</head>'''
    s = s.replace("</head>", helper)

s = s.replace("_fetchLocalJson('./localdb/db.meta.json')", "_fetchLocalJson(__ptoDbBasePath() + '/db.meta.json')")
s = s.replace("_fetchLocalText('./localdb/wb_main.csv')", "_fetchLocalText(__ptoDbBasePath() + '/wb_main.csv')")
s = s.replace("_fetchLocalText('./localdb/opory.csv')", "_fetchLocalText(__ptoDbBasePath() + '/opory.csv')")
s = s.replace("_fetchLocalText('./localdb/lr_base.csv')", "_fetchLocalText(__ptoDbBasePath() + '/lr_base.csv')")
s = s.replace("_fetchLocalText('./localdb/welders.csv')", "_fetchLocalText(__ptoDbBasePath() + '/welders.csv')")
s = s.replace("_fetchLocalText('./localdb/zra.csv').catch(()=>"")", "_fetchLocalText(__ptoDbBasePath() + '/zra.csv').catch(()=>"")")

s = s.replace(
    'const wanted = DB_FILE_NAMES.find((name)=> lower.endsWith("/localdb/" + name) || lower.endsWith("localdb/" + name) || lower.endsWith("/" + name));',
    'const wanted = DB_FILE_NAMES.find((name)=> lower.endsWith("/localdb/" + name) || lower.endsWith("localdb/" + name) || lower.endsWith("/localdb_mobile/" + name) || lower.endsWith("localdb_mobile/" + name) || lower.endsWith("/" + name));'
)
s = s.replace(
    '''    if(requestedFile){
      try{
        const bundle = activeBundle || await loadRemoteBundle(false);
        const text = bundle && bundle.files ? bundle.files[requestedFile] : null;
        if(text == null) return buildTextResponse("Not found", "text/plain; charset=utf-8", 404);
        return buildTextResponse(text, requestedFile.endsWith(".json") ? "application/json; charset=utf-8" : "text/plain; charset=utf-8", 200);
      }catch(err){
        return buildTextResponse(err && err.message ? err.message : String(err), "text/plain; charset=utf-8", 503);
      }
    }''',
    '''    if(requestedFile){
      return origFetch(input, init);
    }'''
)

s = s.replace(
    'fetch("https://raw.githubusercontent.com/Ilya16302/index/main/db.meta.json?_=" + Date.now(), { cache: "no-store" })',
    'fetch(__ptoDbBasePath() + "/db.meta.json?_=" + Date.now(), { cache: "no-store" })'
)
s = s.replace(
    'fetch("./localdb/db.meta.json?_=" + Date.now(), { cache: "no-store" })',
    'fetch(__ptoDbBasePath() + "/db.meta.json?_=" + Date.now(), { cache: "no-store" })'
)

pattern = re.compile(r'''btn\.addEventListener\("click", async \(\)=>\{\s*btn\.disabled = true;\s*const oldText = btn\.textContent;\s*btn\.textContent = "Обновляю…";\s*try\{\s*if\(window\.__ptoRemoteDbBridge && typeof window\.__ptoRemoteDbBridge\.forceRefresh === "function"\)\{\s*await window\.__ptoRemoteDbBridge\.forceRefresh\(\);\s*\}\s*location\.reload\(\);\s*\}catch\(err\)\{\s*console\.error\(err\);\s*alert\("Не удалось обновить базу: " \+ \(err && err\.message \? err\.message : String\(err\)\)\);\s*btn\.disabled = false;\s*btn\.textContent = oldText;\s*\}\s*\}\);''', re.S)

replacement = '''btn.addEventListener("click", async ()=>{
      btn.disabled = true;
      const oldHtml = btn.innerHTML;
      btn.textContent = "Обновляю…";
      try{
        if(typeof tryAutoLoadBundledDb === "function"){
          await tryAutoLoadBundledDb();
        }
        if(typeof render === "function"){
          render(true);
        }
        if(typeof showToast === "function"){
          const tail = __ptoIsMobileDevice() ? " (облегчённая мобильная база)" : "";
          showToast("База", "База обновлена с сервера" + tail + ".", "ok");
        }
        btn.disabled = false;
        btn.innerHTML = oldHtml;
      }catch(err){
        console.error(err);
        alert("Не удалось обновить базу: " + (err && err.message ? err.message : String(err)));
        btn.disabled = false;
        btn.innerHTML = oldHtml;
      }
    });'''

s, n = pattern.subn(replacement, s, count=1)

if n == 0:
    s = s.replace(
        '''        if(window.__ptoRemoteDbBridge && typeof window.__ptoRemoteDbBridge.forceRefresh === "function"){
          await window.__ptoRemoteDbBridge.forceRefresh();
        }
        location.reload();''',
        '''        if(typeof tryAutoLoadBundledDb === "function"){
          await tryAutoLoadBundledDb();
        }
        if(typeof render === "function"){
          render(true);
        }
        btn.disabled = false;
        btn.textContent = oldText;'''
    )

s = s.replace(
    "source: 'локальная база (auto)'",
    "source: (__ptoIsMobileDevice() ? 'локальная база (mobile)' : 'локальная база (auto)')"
)

p.write_text(s, encoding='utf-8')
print("index patched")
PY

echo "[3/5] Проверяю, что мобильная база отдается..."
ls -lh "$MOBILEDB" | sed -n '1,20p'

echo "[4/5] Проверка URL:"
echo "  Обычная база:    http://$(hostname -I | awk '{print $1}')/localdb/db.meta.json"
echo "  Мобильная база:  http://$(hostname -I | awk '{print $1}')/localdb_mobile/db.meta.json"

echo "[5/5] Готово."
echo
echo "Что сделать на iPhone:"
echo "  1) Закрой старую вкладку с сайтом"
echo "  2) Открой сайт заново"
echo "  3) Нажми 'Очистить локальные данные'"
echo "  4) Нажми 'Обновить базу'"
echo
echo "Бэкап:"
echo "  $INDEX.bak.$STAMP"
