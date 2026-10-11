-- 年齢各歳: ズレる前とズレた後を1つの結果に並べる。
--
-- 128列定義（2015ブロックまでを見て作った定義）のまま全ブロックを引く。
-- 位置106 までは 2019 -> 2020 でなめらかに続き、位置107 から最後までの21列が
-- 1つ左にずれる。最終列は対応するデータが無いので NULL になる。
--
-- 実行:
--   ./scripts/run_athena_queries.py --profile "$(cat terraform/.prof.local)" \
--     --sql scripts/sql/nen_boundary.sql --tag gen2
SELECT regexp_extract("$path", '_([0-9]{4})\.csv$', 1) AS block,
       nengetsubi,
       age_99        AS pos105_99sai,
       age_100_plus  AS pos106_100ijou,
       age_unknown   AS pos107_nenrei_fushou,
       age_cls_0_4   AS pos108_0_4,
       age_cls_5_9   AS pos109_5_9,
       age_cls_90_94 AS pos126_90_94,
       age_cls_95_99 AS pos127_95_99
FROM bronze_nenreikakusai_128
WHERE shichoson = '秋田県'
  AND danjo = '男女計（人）'
ORDER BY nengetsubi
