-- 年齢各歳: ずれた列に入っている値が何なのかを確定させる。
--
-- 127列定義（2020ブロックを見て作り直した定義）で同じ行を引く。こちらでは
-- 2020ブロックが正しく読めるので、nen_boundary.sql がずれた位置に出した値と
-- 突き合わせれば「どの年齢階級の値だったのか」が決まる。
--
-- 2020年の正しい値: 0〜4歳 25,345 / 5〜9歳 31,355 / 10〜14歳 36,155 / 95〜99歳 5,570
-- これらが 128列定義では1つ左の列に出る。
--
-- 実行:
--   ./scripts/run_athena_queries.py --profile "$(cat terraform/.prof.local)" \
--     --sql scripts/sql/nen_truth.sql --tag gen2
SELECT block,
       nengetsubi,
       age_100_plus  AS pos106_100ijou,
       age_cls_0_4   AS pos107_0_4,
       age_cls_5_9   AS pos108_5_9,
       age_cls_10_14 AS pos109_10_14,
       age_cls_90_94 AS pos125_90_94,
       age_cls_95_99 AS pos126_95_99
FROM drift_nenreikakusai_127
WHERE shichoson = '秋田県'
  AND danjo = '男女計（人）'
  AND nengetsubi IN ('2019年10月1日現在', '2020年10月1日現在', '2025年10月1日現在')
ORDER BY nengetsubi
