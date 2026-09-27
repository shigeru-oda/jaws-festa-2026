# slides

JAWS FESTA 2026 in AKITA 登壇スライド。公式スライドテンプレート（Google スライド
から配布された `.pptx`）を [Marp](https://marp.app/) のテーマ CSS に移植したもの。

| ファイル | 役割 |
|---|---|
| `template.md` | 素のひな形。元テンプレート5レイアウトのプレースホルダ文字のまま |
| `deck.md` | レイアウト見本。全レイアウトにサンプル文字を入れたもの |
| `themes/jaws-festa-2026.css` | 生成物。marp が読むテーマ |
| `theme-src/jaws-festa-2026.src.css` | テーマの編集元。直すのはこちら |
| `tools/build_theme.py` | src の画像参照を data URI に埋め込んで themes/ を生成する |
| `assets/` | 元テンプレートから抽出した背景・ロゴ |

marp-cli と `tools/build_theme.py` はこのディレクトリを基準に動くので、コマンドは
`slides/` に `cd` してから実行する。

## 書き出す

```bash
cd slides
npx @marp-team/marp-cli --pdf --allow-local-files -o preview/deck.pdf deck.md
npx @marp-team/marp-cli --images png --allow-local-files -o preview/deck.png deck.md
```

テーマは画像を data URI で埋め込んであるのでテーマ自体は単体で完結するが、本文から
`../out/*.png` などを参照するときは `--allow-local-files` が必要になる。

## テーマを直す

`theme-src/jaws-festa-2026.src.css` を編集して、

```bash
cd slides
python3 tools/build_theme.py
```

marp はテーマ CSS を HTML に `<style>` としてインライン展開するため、CSS 内の相対
パスが壊れる。そのため画像を data URI にして1ファイルに閉じている。`assets/` を
差し替えたらこのスクリプトを再実行する。

## レイアウト

Markdown 側は `<!-- _class: ... -->` で切り替える。

| class | 元テンプレ | 用途 |
|---|---|---|
| `title` | 1枚目 TITLE | 表紙。地に稲穂と日の出の線画、右下にエンブレム、下中央にハッシュタグ |
| `section` | 2枚目 SECTION_HEADER | 扉（地色あり）。右に大きいエンブレム |
| `section light` | 3枚目 SECTION_HEADER_1 | 扉（地色を本文と同じ淡色に） |
| 指定なし | 4枚目 TITLE_AND_BODY | 本文。上端にミントのライン、右下に横ロゴ |
| `plain` | 5枚目 TITLE_AND_BODY_1 | 本文（地の柄なし）。図を大きく置くとき |
| `lead` | -- | Marp 側の追加。中央寄せの言い切りスライド |

## 元テンプレートとの対応

元は 1440x810px（720x405pt）。Marp は 1280x720px で組むので座標と文字サイズを
0.8889 倍している（pt からは 1pt = 1.778px）。

| 項目 | 元テンプレ | このテーマ |
|---|---|---|
| 表紙タイトル | 50pt 太字 中央 | 89px |
| 表紙サブタイトル | 26pt 中央 | 46px |
| 扉タイトル | 36pt、左端 x=49.1、上端 y=257.6 | 64px、左 44px、上 229px |
| 本文タイトル | 上端 y=76.6、左右余白 49.1 | 上 68px、左右 44px |
| 本文テキスト | 上端 y=181.5 | 上 161px |
| 上端のライン | #74D4C1、高さ 11.4 | 同色、高さ 10px |
| 地色（表紙・扉） | #90DDCD | 同じ（画像そのまま） |
| 地色（本文） | #F1FBF9 | 同じ（画像そのまま） |

書き出した PNG を測って、表紙タイトル上端 206px（元 200px）、扉のエンブレム上端
213px（元 212px）、本文タイトル上端 74px（元 68px + 字形の余白）を確認済み。

## 元テンプレートから変えたところ

- **フォント**: 元は見出しに Google Sans、和文に BIZ UDPGothic。Google Sans は
  一般配布されていないので全体を BIZ UDPGothic に寄せた（Google Fonts から読み込み）。
  表紙のハッシュタグだけは元と同じ M PLUS Rounded 1c。
- **ページ番号**: 元は扉のみ右下。本文では右下を横ロゴが占めるので左下に置いた。
  `paginate: true` のときだけ出る。
- **背景画像**: 元の PNG（2048px 幅）を 1440px 幅の JPEG に再圧縮した。テーマに
  data URI で埋め込むため。ロゴは透過が必要なので PNG のまま。
- **`lead`**: 元テンプレートにはないレイアウト。

## 素材の出どころ

`assets/` は配布された `.pptx` の `ppt/media/` から抽出したもの。

| ファイル | 元 | 使われ方 |
|---|---|---|
| `bg-cover.jpg` | image7.png | 表紙の地 |
| `bg-section.jpg` | image5.png | 扉（地色あり）の地 |
| `bg-body.jpg` | image2.png | 本文・扉（淡色）の地 |
| `logo-horizontal.png` | image1.png | 本文右下の横ロゴ |
| `logo-emblem.png` | image3.png | 表紙右下・扉右の円形エンブレム |
