"""登壇原稿の見出しの時刻と、セルフチェックの尺表を「話す」文字数から再生成する。

原稿を書き換えたら手で時刻を直すのではなくこれを走らせる。

    uv run python scripts/retime_talk_script.py            # 書き換える
    uv run python scripts/retime_talk_script.py --check     # 差分があれば exit 1(書き換えない)

前提: 日本語の朗読 300字/分、間とスライド送りで 1.10 倍、1枚あたり最低 20 秒。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "docs" / "talk-script.md"

CPM = 300
OVERHEAD = 1.10
MIN_SLIDE_SECS = 20
SLOT_SECS = 15 * 60

GROUPS = [
    ("S1-S4 (今の秋田〜カタログ)", ["S1", "S2", "S3", "S4"]),
    ("S5-S8 (第1段: 名前が変わる)", ["S5", "S6", "S7", "S8"]),
    ("S9-S11 (列が消える / S3 Tables)", ["S9", "S10", "S11"]),
    ("S12-S15 (速度/判断/締め)", ["S12", "S13", "S14", "S15"]),
]

HEADER_RE = re.compile(r"^## (S\d+) — (.+?) \(.*?\)\s*$")


def mmss(secs: float) -> str:
    return f"{int(secs) // 60}:{int(secs) % 60:02d}"


def collect(lines: list[str]) -> tuple[list[str], dict[str, str]]:
    """節の順番と、節ごとの「話す」原稿を返す。"""
    order: list[str] = []
    spoken: dict[str, list[str]] = {}
    cur: str | None = None
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            cur = m.group(1)
            order.append(cur)
            spoken[cur] = []
            continue
        if line.startswith("## セルフチェック"):
            cur = None
        if cur and line.startswith("> ") and "**話す**" not in line and "【要実測】" not in line:
            spoken[cur].append(line[2:].strip())
    return order, {k: "".join(v) for k, v in spoken.items()}


def secs_of(text: str) -> float:
    return max(len(text) / CPM * 60 * OVERHEAD, MIN_SLIDE_SECS)


def build(src: str) -> str:
    lines = src.splitlines()
    order, spoken = collect(lines)
    secs = {k: secs_of(spoken[k]) for k in order}

    start: dict[str, float] = {}
    t = 0.0
    for k in order:
        start[k] = t
        t += secs[k]
    total = t

    out: list[str] = []
    for line in lines:
        m = HEADER_RE.match(line)
        if m and m.group(1) in secs:
            k = m.group(1)
            a, b = start[k], start[k] + secs[k]
            line = f"## {k} — {m.group(2)} ({mmss(a)}-{mmss(b)} / {int(secs[k])}秒)"
        out.append(line)
    s = "\n".join(out) + "\n"

    # セルフチェックの尺表を作り直す
    rows = [
        "| 区間 | 話す文字数(実測) | 朗読 300字/分 | 実演時間(間+送り 1.10倍) |",
        "|---|---|---|---|",
    ]
    total_chars = 0
    for name, keys in GROUPS:
        chars = sum(len(spoken[k]) for k in keys)
        total_chars += chars
        rows.append(
            f"| {name} | {chars:,}字 | {mmss(chars / CPM * 60)} | "
            f"**{mmss(sum(secs[k] for k in keys))}** |"
        )
    rows.append(
        f"| **合計** | **{total_chars:,}字** | **{mmss(total_chars / CPM * 60)}** | "
        f"**{mmss(total)}** |"
    )
    table = "\n".join(rows)

    body = f"""{table}

`docs/talk-script.md` の「話す」ブロックだけを機械的に数えた実測値。
数え直しは `uv run python scripts/retime_talk_script.py`(見出しもこの表も再生成する)。

- 15分枠に対して **{mmss(SLOT_SECS - total)} の余裕**。質疑が枠内なら1〜2問。枠外なら緩衝に使う
- 速く話す人(330字/分)なら {total_chars / 330:.1f}分、ゆっくり(270字/分)でも {total_chars / 270:.1f}分
- **最長の節は {max(order, key=lambda k: secs[k])} と {sorted(order, key=lambda k: -secs[k])[1]}**。
  ここが崩れると全体が崩れるので、リハーサルはこの2つを繰り返す"""

    pat = re.compile(r"(### 2\. 尺の見積もり\n\n)(.*?)(\n\n### 3\.)", re.S)
    if not pat.search(s):
        raise SystemExit("セルフチェックの『### 2. 尺の見積もり』節が見つからない")
    return pat.sub(lambda m: m.group(1) + body + m.group(3), s)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="書き換えず差分の有無だけ見る")
    args = ap.parse_args()

    src = SCRIPT.read_text(encoding="utf-8")
    new = build(src)

    if src == new:
        print("尺は最新です(変更なし)")
        return 0
    if args.check:
        print("NG: 見出しか尺表が話す文字数と合っていません。--check なしで再生成してください")
        return 1
    SCRIPT.write_text(new, encoding="utf-8")
    print("再生成しました:", SCRIPT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
