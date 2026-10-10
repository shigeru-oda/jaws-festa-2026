-- 人口移動理由(CKAN 050008_toukeika_039)を 19 列定義のまま 2013〜2025 年で読む。
--
-- 配布が 2019 年から 16 列(8 理由)に変わるので、19 列定義で読むと位置 9 以降が
-- 別項目の値を返し、位置 16〜18 が NULL になる。列位置は 0 始まり。
--
--   位置 14 kekkon_rikon  : 2013〜2018 は結婚・離婚、2019〜 は住宅事情の値
--   位置 16〜18           : 2019〜 は対応する列が無いので NULL
--
-- identity_broken は「総数 = 11 理由の合計」の検算。19 列でも 16 列でも成立して
-- しまうので 0 のまま。つまり素直な検算ではこのズレを検知できない。
SELECT substr(nengetsubi_code, 1, 4)                             AS nen,
       count(*)                                                  AS rows_total,
       count(kekkon_rikon)                                       AS pos14_nonnull,
       count(ko_mago_to_dokyo)                                   AS pos16_nonnull,
       count(jutaku_jijo)                                        AS pos17_nonnull,
       count(sonota)                                             AS pos18_nonnull,
       max(CASE
               WHEN idou_kubun_code = '1' AND danjo_code = '0' AND nenrei_kaikyu = '総数'
                   THEN kekkon_rikon
           END)                                                  AS kekkon_rikon_kengai_sokei,
       max(CASE
               WHEN idou_kubun_code = '1' AND danjo_code = '0' AND nenrei_kaikyu = '総数'
                   THEN shingaku_tenko
           END)                                                  AS shingaku_tenko_kengai_sokei,
       sum(CASE
               WHEN sosu <> coalesce(tenkin, 0) + coalesce(tengyo_tenshoku, 0)
                   + coalesce(shushoku, 0) + coalesce(kagyo_kokei, 0)
                   + coalesce(shingaku_tenko, 0) + coalesce(sotsugyo, 0)
                   + coalesce(kekkon_rikon, 0) + coalesce(oya_to_dokyo, 0)
                   + coalesce(ko_mago_to_dokyo, 0) + coalesce(jutaku_jijo, 0)
                   + coalesce(sonota, 0)
                   THEN 1
               ELSE 0
           END)                                                  AS identity_broken
FROM jaws_festa_2026_akita.idouriyuu_csv
GROUP BY substr(nengetsubi_code, 1, 4)
ORDER BY nen
