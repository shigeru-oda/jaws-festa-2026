---
marp: true
theme: jaws-festa-2026
paginate: true
---

<!-- _class: title -->
<!-- _paginate: false -->

# セッションタイトルを追加

所属名　名前

---

<!-- _class: section -->

# セクションタイトルが入ります

---

<!-- _class: section light -->

# 地色なしの扉

同じ配置で、地色を本文と同じ淡色にしたもの

---

# スライドタイトルを追加

コンテンツが入ります。ご自由に調整してください。

- 箇条書きの1行目
- 箇条書きの2行目
  - ネストした行
- 箇条書きの3行目

---

# 表とコード

| 列 | 値 | 備考 |
|---|---:|---|
| CSV を持つデータセット | 114 | カタログ264件中 |
| Excel だけのデータセット | 138 | 変換が必要 |

```sql
SELECT prefecture, SUM(population)
FROM akita.monthly_population
GROUP BY prefecture
```

---

<!-- _class: plain -->

# 無地の本文

地の柄を外したレイアウト。図やスクリーンショットを大きく置くときに使う。

---

<!-- _class: lead -->

# 言い切りのスライド

Marp 側で足したレイアウト
