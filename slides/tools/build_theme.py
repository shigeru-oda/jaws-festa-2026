#!/usr/bin/env python3
"""theme-src/jaws-festa-2026.src.css の url('../assets/*') を data URI に埋め込んで
themes/jaws-festa-2026.css を生成する。

Marp はテーマ CSS を HTML に <style> としてインライン展開するため、CSS 内の
相対パスは出力 HTML の位置を基準に解決されて壊れる。単一ファイルで完結させる
ために画像を data URI にしている。素材を差し替えたらこのスクリプトを再実行する。

    python3 tools/build_theme.py
"""

from __future__ import annotations

import base64
import mimetypes
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "theme-src" / "jaws-festa-2026.src.css"
DST = ROOT / "themes" / "jaws-festa-2026.css"
PATTERN = re.compile(r"url\(\s*'\.\./assets/([^']+)'\s*\)")


def to_data_uri(name: str) -> str:
    path = ROOT / "assets" / name
    if not path.is_file():
        sys.exit(f"asset not found: {path}")
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    payload = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"url('data:{mime};base64,{payload}')"


def var_name(asset: str) -> str:
    stem = Path(asset).stem.replace("_", "-")
    return f"--festa-img-{stem}"


def main() -> None:
    css = SRC.read_text(encoding="utf-8")
    used: list[str] = []

    def repl(m: re.Match[str]) -> str:
        # 同じ素材を複数のルールが参照するので、data URI は :root に一度だけ置き、
        # 各ルールからは var() で参照する（CSS の肥大を防ぐ）。
        used.append(m.group(1))
        return f"var({var_name(m.group(1))})"

    out = PATTERN.sub(repl, css)
    decls = "\n".join(
        f"  {var_name(name)}: {to_data_uri(name)};" for name in sorted(set(used))
    )
    block = (
        "/* GENERATED: assets embedded as data URI - "
        "edit theme-src/jaws-festa-2026.src.css and run "
        "`python3 tools/build_theme.py` */\n"
        f":root {{\n{decls}\n}}\n"
    )
    # CSS 仕様上 @import は他のルールより前に置く必要がある。生成ブロックは
    # 最後の @import の直後に差し込む（先頭に置くと @import が無効になる）。
    imports = list(re.finditer(r"^@import[^;]*;\s*$", out, flags=re.MULTILINE))
    pos = imports[-1].end() if imports else 0
    out = out[:pos] + "\n\n" + block + out[pos:]
    DST.write_text(out, encoding="utf-8")
    print(f"wrote {DST.relative_to(ROOT)} ({DST.stat().st_size / 1024:.0f} KB)")
    for name in sorted(set(used)):
        print(f"  embedded assets/{name}")


if __name__ == "__main__":
    main()
