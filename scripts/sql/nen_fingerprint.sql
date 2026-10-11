-- 年齢各歳: 定義を直すとズレが無痕跡になることを測る。
--
-- 最終列の非NULL件数を両定義で数える。count(列) は NULL を数えないので、
-- 「行数 = 非NULL件数」なら痕跡なし、「非NULL件数 = 0」なら NULL の指紋あり。
-- 表示上の空欄と本物の NULL を取り違えないよう、count で数えている。
--
-- 期待値:
--   128列定義 x 2015ブロック  390 / 390   正常
--   128列定義 x 2020ブロック  468 /   0   NULL の指紋が出る
--   127列定義 x 2015ブロック  390 / 390   ずれているのに痕跡なし
--   127列定義 x 2020ブロック  468 / 468   正常
--
-- 127列定義が古いブロックを読むと、CSV の128列目（真の95〜99歳）を受け取る列が
-- 無いので黙って捨てられる。欠けるのではなく余るため NULL も出ない。
--
-- 実行:
--   ./scripts/run_athena_queries.py --profile "$(cat terraform/.prof.local)" \
--     --sql scripts/sql/nen_fingerprint.sql --tag gen2
SELECT '128列定義' AS teigi,
       block,
       count(*)             AS gyo,
       count(age_cls_95_99) AS saishuretsu_nonnull
FROM (SELECT *, regexp_extract("$path", '_([0-9]{4})\.csv$', 1) AS block FROM bronze_nenreikakusai_128)
WHERE block IN ('2015', '2020')
GROUP BY block
UNION ALL
SELECT '127列定義' AS teigi,
       block,
       count(*)             AS gyo,
       count(age_cls_95_99) AS saishuretsu_nonnull
FROM (SELECT *, regexp_extract("$path", '_([0-9]{4})\.csv$', 1) AS block FROM bronze_nenreikakusai_127)
WHERE block IN ('2015', '2020')
GROUP BY block
ORDER BY teigi DESC, block
