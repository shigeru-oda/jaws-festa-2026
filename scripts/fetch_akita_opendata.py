#!/usr/bin/env python3
"""秋田県オープンデータカタログ(CKAN)から CSV 形式のリソースを全部落とす。

出典: 秋田県オープンデータカタログサイト <https://ckan.pref.akita.lg.jp/> (CC BY 4.0)

    ./scripts/fetch_akita_opendata.py                 # 50MB 以下の CSV を全部
    ./scripts/fetch_akita_opendata.py --max-mb 0      # サイズ上限なし(地震被害想定の格子データ 3.4GB も落とす)
    ./scripts/fetch_akita_opendata.py --dataset 050008_toukeika_039

保存先は data/akita_opendata/<データセット名>/<リソースID先頭8桁>_<元のファイル名>。
同じ場所に manifest.json(取得したもの・飛ばしたものと理由)を書く。
landing へはこのディレクトリをそのまま上げる(scripts/upload_opendata_landing.sh)。

ポータル上で形式が CSV になっていても中身が XLSX のリソースがあるので、先頭バイトで判定して
CSV でないものは保存せず manifest に not_csv として残す。標準ライブラリだけで動く。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

CKAN = "https://ckan.pref.akita.lg.jp"
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "data" / "akita_opendata"
UA = "jaws-festa-2026-verification (+https://github.com/)"

# 先頭バイトで「CSV ではない」と分かるもの
MAGIC = {
    b"PK\x03\x04": "zip/xlsx",
    b"\xd0\xcf\x11\xe0": "xls",
    b"%PDF": "pdf",
}


def get(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception:  # noqa: BLE001 ネットワークの一時エラーは3回まで再試行
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))
    raise AssertionError("unreachable")


def list_csv_packages() -> list[dict]:
    q = urllib.parse.urlencode({"rows": 1000, "fq": "res_format:CSV"})
    res = json.loads(get(f"{CKAN}/api/3/action/package_search?{q}"))["result"]
    if res["count"] > len(res["results"]):
        sys.exit(f"データセットが {res['count']} 件あり1回で取り切れない。ページングを実装すること")
    return res["results"]


def local_name(res: dict) -> str:
    base = os.path.basename(urllib.parse.urlparse(res["url"]).path) or "resource"
    stem = base.rsplit(".", 1)[0] if "." in base else base
    # 同じデータセット内でファイル名が重複するリソースがあるので ID で区別する
    return f"{res['id'][:8]}_{stem}.csv"


def fetch_one(pkg: dict, res: dict, max_bytes: int) -> dict:
    ds = pkg["name"]
    entry = {
        "dataset": ds,
        "dataset_title": pkg["title"],
        "dataset_url": f"{CKAN}/dataset/{ds}",
        "organization": (pkg.get("organization") or {}).get("title"),
        "license": pkg.get("license_id"),
        "resource_id": res["id"],
        "resource_name": res.get("name"),
        "url": res["url"],
        "last_modified": res.get("last_modified") or res.get("created"),
        "size_declared": res.get("size"),
        "file": f"{ds}/{local_name(res)}",
    }
    if max_bytes and (res.get("size") or 0) > max_bytes:
        return entry | {"status": "skipped_large"}
    try:
        raw = get(res["url"])
    except Exception as e:  # noqa: BLE001
        return entry | {"status": "error", "error": f"{type(e).__name__}: {e}"}
    for magic, kind in MAGIC.items():
        if raw.startswith(magic):
            return entry | {"status": "not_csv", "detected": kind, "bytes": len(raw)}
    out = DEST / entry["file"]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(raw)
    return entry | {
        "status": "ok",
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--max-mb", type=float, default=50, help="これより大きいリソースは飛ばす(0 で無制限)。既定 50")
    ap.add_argument("--dataset", action="append", help="データセット名で絞る(複数可)")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    pkgs = list_csv_packages()
    if args.dataset:
        pkgs = [p for p in pkgs if p["name"] in set(args.dataset)]
    jobs = [
        (p, r)
        for p in pkgs
        for r in p["resources"]
        if (r.get("format") or "").strip().upper() == "CSV"
    ]
    max_bytes = int(args.max_mb * 1e6)
    print(f"データセット {len(pkgs)} 件 / CSV リソース {len(jobs)} 本", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        entries = list(ex.map(lambda j: fetch_one(*j, max_bytes), jobs))

    by_status: dict[str, int] = {}
    for e in entries:
        by_status[e["status"]] = by_status.get(e["status"], 0) + 1
    manifest = {
        "source": CKAN,
        "license": "CC BY 4.0 (秋田県オープンデータカタログサイト)",
        "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "max_mb": args.max_mb,
        "summary": by_status,
        "resources": sorted(entries, key=lambda e: e["file"]),
    }
    DEST.mkdir(parents=True, exist_ok=True)
    (DEST / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps(by_status, ensure_ascii=False), file=sys.stderr)
    for e in entries:
        if e["status"] == "error":
            print(f"  error: {e['file']}: {e['error']}", file=sys.stderr)


if __name__ == "__main__":
    main()
