create or replace package body schema_analytics.customer_segmentation_engine as

procedure log_time_taken (p_ref_date IN DATE, p_step_name IN VARCHAR2, p_start DATE, p_end DATE) AS
   PRAGMA AUTONOMOUS_TRANSACTION;
 BEGIN
   insert into schema_analytics.process_log_table
        (day, step_name, starts, ends, inserted)
      values
        (p_ref_date, p_step_name, p_start, p_end, trunc(sysdate));
   COMMIT;
 END;

 FUNCTION calculate_tier_level (  p_source_table IN VARCHAR2
                         , p_depositor IN NUMBER
                         , p_flag_b IN NUMBER
                         , p_metric_a_90d IN NUMBER
                         , p_metric_b_90d IN NUMBER
                         , p_metric_c_90d IN NUMBER
                         , p_flag_c IN NUMBER
                         , p_factor_x IN NUMBER
                         )
    RETURN NUMBER
    PARALLEL_ENABLE DETERMINISTIC
  AS
   x_tier_level NUMBER;
  BEGIN
      IF p_source_table ='source_system_a.entity_table_a' AND p_depositor = 1 AND (p_flag_b = 0 OR p_flag_c = 0) AND p_factor_x >= [THRESHOLD_1]  THEN
        x_tier_level := CASE WHEN p_metric_c_90d >= [THRESHOLD_A] THEN 1
                            WHEN p_metric_c_90d >= [THRESHOLD_B] THEN 2
                            WHEN p_metric_c_90d >= [THRESHOLD_C] THEN 3
                            WHEN p_metric_c_90d >= [THRESHOLD_D] THEN 4
                            ELSE NULL END;
      ELSIF p_source_table <> 'source_system_a.entity_table_a' AND p_depositor = 1 AND (p_flag_b = 0 OR p_flag_c = 0) THEN
        x_tier_level := CASE WHEN greatest(p_metric_a_90d, p_metric_b_90d) >= [THRESHOLD_A] THEN 1
                            WHEN greatest(p_metric_a_90d, p_metric_b_90d) >= [THRESHOLD_B] THEN 2
                            WHEN greatest(p_metric_a_90d, p_metric_b_90d) >= [THRESHOLD_C] THEN 3
                            WHEN greatest(p_metric_a_90d, p_metric_b_90d) >= [THRESHOLD_D] THEN 4
                            ELSE NULL END;
      ELSE
        x_tier_level := NULL;
      END IF;
      RETURN x_tier_level;
  END;

 FUNCTION get_tier_users (  p_source_table IN VARCHAR2
                           , p_depositor IN NUMBER
                           , p_flag_b IN NUMBER
                           , p_metric_a_90d IN NUMBER
                           , p_metric_b_90d IN NUMBER
                           , p_flag_c IN NUMBER
                           , p_factor_x IN NUMBER
                           , p_metric_c_90d IN NUMBER
                           )
    RETURN VARCHAR2
    PARALLEL_ENABLE DETERMINISTIC
  AS
   x_tier_status VARCHAR2(7);
  BEGIN
        IF p_source_table ='source_system_a.entity_table_a' THEN
           x_tier_status := CASE WHEN p_depositor = 1 AND (p_flag_b = 0 OR p_flag_c = 0) AND p_factor_x >= [THRESHOLD_1] AND p_metric_c_90d >= [THRESHOLD_D] THEN 'TIER_1' END;
        ELSE
           x_tier_status := CASE WHEN p_depositor = 1 AND (p_flag_b = 0 OR p_flag_c = 0) AND greatest(p_metric_a_90d, p_metric_b_90d) >= [THRESHOLD_D] THEN 'TIER_1' END;
        END IF;
        RETURN x_tier_status;
  END;

 FUNCTION calculate_segment (  p_source_table IN VARCHAR2
                              , p_depositor IN NUMBER
                              , p_metric_a_active_90d IN NUMBER
                              , p_metric_b_active_90d IN NUMBER
                              , p_metric_c_active_90d IN NUMBER
                           )
    RETURN VARCHAR2
    PARALLEL_ENABLE DETERMINISTIC
  AS
   x_segment VARCHAR2(20);
  BEGIN
      IF p_depositor = 0 THEN
         x_segment := 'SEG_F';
      ELSIF p_source_table ='source_system_a.entity_table_a' THEN
            x_segment := CASE WHEN p_metric_c_active_90d < [VAL_1]   THEN 'SEG_E'
                         WHEN p_metric_c_active_90d >= [VAL_1]  AND p_metric_c_active_90d < [VAL_2]  THEN 'SEG_D_LOW'
                         WHEN p_metric_c_active_90d >= [VAL_2]  AND p_metric_c_active_90d < [VAL_3]  THEN 'SEG_D'
                         WHEN p_metric_c_active_90d >= [VAL_3]  AND p_metric_c_active_90d < [VAL_4]  THEN 'SEG_C'
                         WHEN p_metric_c_active_90d >= [VAL_4]  THEN 'SEG_B'
                    END;
      ELSIF p_source_table ='source_system_b.entity_table_b' THEN
            x_segment := CASE WHEN p_metric_a_active_90d < [VAL_1]   THEN 'SEG_E'
                         WHEN p_metric_a_active_90d >= [VAL_1]  AND p_metric_a_active_90d < [VAL_2]  THEN 'SEG_D_LOW'
                         WHEN p_metric_a_active_90d >= [VAL_2]  AND p_metric_a_active_90d < [VAL_3]  THEN 'SEG_D'
                         WHEN p_metric_a_active_90d >= [VAL_3]  AND p_metric_a_active_90d < [VAL_4]  THEN 'SEG_C'
                         WHEN p_metric_a_active_90d >= [VAL_4]  THEN 'SEG_B'
                    END;
      ELSE
            x_segment := CASE WHEN greatest(p_metric_a_active_90d, p_metric_b_active_90d) < [VAL_1]   THEN 'SEG_E'
                         WHEN greatest(p_metric_a_active_90d, p_metric_b_active_90d) >= [VAL_1]  AND greatest(p_metric_a_active_90d, p_metric_b_active_90d) < [VAL_2]  THEN 'SEG_D_LOW'
                         WHEN greatest(p_metric_a_active_90d, p_metric_b_active_90d) >= [VAL_2]  AND greatest(p_metric_a_active_90d, p_metric_b_active_90d) < [VAL_3]  THEN 'SEG_D'
                         WHEN greatest(p_metric_a_active_90d, p_metric_b_active_90d) >= [VAL_3]  AND greatest(p_metric_a_active_90d, p_metric_b_active_90d) < [VAL_4]  THEN 'SEG_C'
                         WHEN greatest(p_metric_a_active_90d, p_metric_b_active_90d) >= [VAL_4]  THEN 'SEG_B'
                    END;
      END IF;
      RETURN x_segment;
  END;

 procedure run_refresh_daily(p_message    out varchar2
                            , p_ref_date   in date default TRUNC(SYSDATE)
    ) is

    l_start  date;
    l_ref_date  date := p_ref_date;
    l_min_date_num number := to_number(to_char(to_date('11/11/1111','dd/mm/yyyy'),'ddmmyyyy'));
    l_max_date date := to_date('31/12/9999','dd/mm/yyyy');
    l_fp_min_date date;
    l_default_tier_level number := 999;

  begin

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_get_entity_details');
      select sysdate into l_start from dual;
      EXECUTE IMMEDIATE 'truncate table schema_analytics.tmp_active_entities_all';

      insert /*+ APPEND */into schema_analytics.tmp_active_entities_all
      with live_entity as (
          SELECT FIRST_VALUE(kambi_category_w) OVER (PARTITION BY user_no ORDER BY scd_current_record DESC) kambi_category_w
               , FIRST_VALUE(p.first_transaction_date) OVER (PARTITION BY user_no ORDER BY scd_current_record DESC) first_transaction_date
               , p.punter_key
               , p.user_no
               , p.entity_group
               , p.scd_current_record
               , ref.source_table
           from source_system_b.entity_table_b p
           join schema_dim.entity_groups ref
             on ref.entity_group = p.entity_group
            and ref.source_table in ('source_system_b.entity_table_b')
            and ref.active='Y'
      )
      , entities as (
      select p.punter_key
           , p.user_no
           , p.entity_group
           , CASE WHEN p.kambi_category_w='Y' THEN 1 ELSE 0 END kambi_category_w
           , case when p.first_transaction_date is not null
                    and p.first_transaction_date < l_ref_date
                  then 1 else 0 end as first_transaction_date
           , p.source_table
        from live_entity p
      UNION ALL
      select p.punter_key, p.user_no, p.entity_group
           , 0 as kambi_category_w
           , case when p.first_transaction_date is not null
                    and p.first_transaction_date < l_ref_date
                  then 1 else 0 end as first_transaction_date
           , ref.source_table
        from source_system_c.entity_table_c p
        join schema_dim.entity_groups ref
          on ref.entity_group = p.entity_group
         and ref.source_table in ('source_system_c.entity_table_c')
         and ref.active='Y'
       WHERE user_no is not null
      UNION ALL
      select p.punter_key, p.user_no
           , 'group_a' as entity_group
           , 0 as kambi_category_w
           , case when p.first_transaction_date is not null
                    and p.first_transaction_date < l_ref_date
                  then 1 else 0 end first_transaction_date
           , 'source_system_a.entity_table_a' as source_table
        from source_system_a.entity_table_a p
      )
      , live_data_all as (
              select p.punter_key
                   , p.entity_group
                   , to_number(to_char(d.last_active_date,'yyyymmdd')) time_key
                from entities p
                join schema_analytics.tracking_live_data d
                  on d.user_no = p.user_no
                 and d.entity_group = p.entity_group
      )
      , fact_data as (
              SELECT p.punter_key, p.entity_group, max(time_key) time_key
                  FROM schema_analytics.fact_entity f
                  JOIN entities p ON f.punter_key = p.punter_key
                 WHERE indicator_key = 48
                   AND time_key >= to_char(l_ref_date - 90,'yyyymmdd')
                   AND time_key < to_char(l_ref_date,'yyyymmdd')
              GROUP BY p.punter_key, p.entity_group
      )
      , last_active_all as (
                select coalesce(u.punter_key, v.punter_key) as punter_key
                     , coalesce(u.entity_group, v.entity_group) as entity_group
                     , greatest(coalesce(v.time_key, l_min_date_num), coalesce(u.time_key, l_min_date_num)) as time_key
                  from live_data_all v
             full join fact_data u on u.punter_key = v.punter_key
      )
      SELECT /*+ materialize PARALLEL (8) optimizer_features_enable('19.1.0.0') */
             p.user_no, p.entity_group, max(la.time_key) as time_key
           , p.kambi_category_w, p.first_transaction_date as depositor, p.source_table
      FROM entities p
      join last_active_all la on la.punter_key = p.punter_key
      group by p.user_no, p.entity_group, p.kambi_category_w, p.first_transaction_date, p.source_table;

      COMMIT;
      log_time_taken(l_ref_date,'step_get_entity_details', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_calculate_metrics');
      select sysdate into l_start from dual;

      SELECT min(vs.last_active_date) - 90
        INTO l_fp_min_date
        FROM schema_analytics.tracking_live_data vs
       WHERE vs.entity_group IN (SELECT entity_group FROM schema_dim.entity_groups WHERE active = 'Y')
         AND vs.segment_value ='TIER_1'
         AND vs.last_active_date < l_ref_date - 90;

      EXECUTE IMMEDIATE 'truncate table schema_analytics.tmp_tracking_live_data';

      insert /*+ APPEND */into schema_analytics.tmp_tracking_live_data t (user_no, entity_group,
                                                          last_active_date, kambi_category_w, depositor,
                                                          metric_a_last_90d, metric_b_last_90d,
                                                          metric_bonus_last_90d, metric_c_last_90d,
                                                          bonus_pct_last_90d, metric_a_last_active_90d,
                                                          metric_b_last_active_90d, metric_bonus_last_active_90d,
                                                          metric_c_last_active_90d, bonus_pct_last_active_90d,
                                                          source_table, factor_x, margin_last_active_90d,
                                                          flag_c, most_frequent_segment, days_on_frequent_segment)
      with entities as (
                    select /*+ no_index(p) */ p.punter_key, p.user_no, p.entity_group, 0 as factor_x
                      from source_system_b.entity_table_b p
                      join schema_dim.entity_groups ref
                        on ref.entity_group = p.entity_group
                       and ref.source_table in ('source_system_b.entity_table_b')
                       and ref.active='Y'
                 UNION ALL
                    select /*+ no_index(p) */p.punter_key, p.user_no, p.entity_group, 0 as factor_x
                      from source_system_c.entity_table_c p
                      join schema_dim.entity_groups ref
                        on ref.entity_group = p.entity_group
                       and ref.source_table in ('source_system_c.entity_table_c')
                       and ref.active='Y'
                     WHERE user_no is not null
                 UNION ALL
                    select /*+ no_index(p) */p.punter_key, p.user_no, 'group_a' as entity_group, calculation_factor
                      from source_system_a.entity_table_a p
        )
        , entities_active_last_90d as (
                   SELECT a.user_no, a.entity_group, a.time_key, a.kambi_category_w, a.depositor, a.source_table
                     FROM schema_analytics.tmp_active_entities_all a
                    WHERE a.time_key >= to_char(l_ref_date - 90,'yyyymmdd')
              UNION
                     SELECT vs.user_no, vs.entity_group, a.time_key, a.kambi_category_w, a.depositor, ref.source_table
                      FROM schema_analytics.tracking_live_data vs
                      JOIN schema_analytics.tmp_active_entities_all a
                        ON vs.user_no = a.user_no AND vs.entity_group = a.entity_group
                      JOIN schema_dim.entity_groups ref
                        on ref.entity_group = vs.entity_group
                       and ref.source_table in ('source_system_b.entity_table_b','source_system_c.entity_table_c','source_system_a.entity_table_a')
                       and ref.active='Y'
                     WHERE segment_value ='TIER_1'
                       AND a.time_key < to_char(l_ref_date - 90,'yyyymmdd')
        )
        , historical_segments as (
          SELECT hist.user_no, hist.entity_group
               , SUM(coalesce(hist.valid_to, trunc(l_ref_date)) - greatest(hist.valid_from, trunc(l_ref_date) - 90)) as days_on_segment
               , hist.segment_value
            FROM schema_analytics.segment_history_table hist
            JOIN entities_active_last_90d a ON hist.user_no = a.user_no AND hist.entity_group = a.entity_group
           WHERE hist.last_active_date >= l_ref_date - 90
           GROUP BY hist.user_no, hist.entity_group, hist.segment_value
        )
        , segment_ranking as (
          SELECT h.user_no, h.entity_group, h.segment_value, h.days_on_segment
               , ROW_NUMBER() OVER(PARTITION BY user_no, entity_group ORDER BY days_on_segment DESC, segment_value) as ranking
            FROM historical_segments h
        )
        , most_common_segments as (
          SELECT r.user_no, r.entity_group, r.segment_value most_frequent_segment, r.days_on_segment days_on_frequent_segment
            FROM segment_ranking r WHERE ranking = 1
        )
        , entities_active_last_90d_detail as (
                   SELECT a.user_no, a.entity_group, a.time_key as last_active_date, p.punter_key, p.factor_x
                     FROM entities_active_last_90d a
                     JOIN entities p ON p.user_no = a.user_no AND p.entity_group = a.entity_group
        )
        , fact_subset as (
                    SELECT /*+materialize */ *
                     FROM schema_analytics.fact_entity f
                     WHERE f.indicator_key in (
                            [INDICATOR_1],[INDICATOR_2],[INDICATOR_3],[INDICATOR_4],[INDICATOR_5],
                            [INDICATOR_6],[INDICATOR_7],[INDICATOR_8],[INDICATOR_9],[INDICATOR_10],
                            [INDICATOR_11],[INDICATOR_12],[INDICATOR_13],[INDICATOR_14],[INDICATOR_15],
                            [INDICATOR_16],[INDICATOR_17])
                       AND f.time_key >= to_char(coalesce(l_fp_min_date, l_ref_date - 180),'yyyymmdd')
                       AND f.time_key < to_char(l_ref_date,'yyyymmdd')
        )
        , fact_last_90d as (
            SELECT * FROM fact_subset
             WHERE time_key >= to_char(l_ref_date - 90,'yyyymmdd')
               and time_key < to_char(l_ref_date,'yyyymmdd')
        )
        , totals_last_90d as (
                       SELECT  p.user_no, p.entity_group
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_2] then f.indicator_value end), 0) as metric_a_last_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_3] then f.indicator_value*adjustment_factor end), 0) as metric_b_last_90d
                             , coalesce(sum(case when f.indicator_key in ([INDICATOR_4],[INDICATOR_5],[INDICATOR_6],[INDICATOR_7],[INDICATOR_8],[INDICATOR_9],[INDICATOR_10],[INDICATOR_11],[INDICATOR_12],[INDICATOR_13],[INDICATOR_14],[INDICATOR_15],[INDICATOR_16],[INDICATOR_17]) then f.indicator_value end), 0) as metric_bonus_last_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_1] then f.indicator_value end), 0) as metric_c_last_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_3] then f.indicator_value end), 0) as volume_last_90d
                        from entities_active_last_90d_detail p
                   left join fact_last_90d f on p.punter_key = f.punter_key
                   left join schema_analytics.adjustment_factors m on f.category_key=m.category_key
                    group by p.user_no, p.entity_group
        )
        , totals_last_active_90d as (
                       SELECT p.user_no, p.entity_group, p.factor_x
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_2] then f.indicator_value end), 0) as metric_a_last_active_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_3] then f.indicator_value*adjustment_factor end), 0) as metric_b_last_active_90d
                             , coalesce(sum(case when f.indicator_key in ([INDICATOR_4],[INDICATOR_5],[INDICATOR_6],[INDICATOR_7],[INDICATOR_8],[INDICATOR_9],[INDICATOR_10],[INDICATOR_11],[INDICATOR_12],[INDICATOR_13],[INDICATOR_14],[INDICATOR_15],[INDICATOR_16],[INDICATOR_17]) then f.indicator_value end), 0) as metric_bonus_last_active_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_1] then f.indicator_value end), 0) as metric_c_last_active_90d
                             , coalesce(sum(case when f.indicator_key=[INDICATOR_3] then f.indicator_value end), 0) as volume_last_active_90d
                        from entities_active_last_90d_detail p
                   left join fact_subset f on p.punter_key = f.punter_key
                          and time_key >= to_char(to_date(p.last_active_date,'yyyy/mm/dd') - 89,'yyyymmdd')
                          and time_key <= p.last_active_date
                   left join schema_analytics.adjustment_factors m on f.category_key = m.category_key
                      group by p.user_no, p.entity_group, p.factor_x
        )
        , aggregated_metrics as (
                        SELECT /*+ USE_HASH(la, l) */
                                la.entity_group, la.user_no, la.factor_x
                              , sum(l.metric_a_last_90d)           as metric_a_last_90d
                              , sum(l.metric_b_last_90d)            as metric_b_last_90d
                              , sum(l.metric_bonus_last_90d)          as metric_bonus_last_90d
                              , sum(l.metric_c_last_90d)            as metric_c_last_90d
                              , case when sum(l.metric_c_last_90d) = 0 then 0 else sum(l.metric_bonus_last_90d) / sum(l.metric_c_last_90d) end as bonus_pct_last_90d
                              , sum(la.metric_a_last_active_90d)   as metric_a_last_active_90d
                              , sum(la.metric_b_last_active_90d)    as metric_b_last_active_90d
                              , sum(la.metric_bonus_last_active_90d) as metric_bonus_last_active_90d
                              , sum(la.metric_c_last_active_90d)    as metric_c_last_active_90d
                              , case when sum(la.metric_c_last_active_90d) = 0 then 0 else sum(la.metric_bonus_last_active_90d) / sum(la.metric_c_last_active_90d) end as bonus_pct_last_active_90d
                              , case when sum(la.volume_last_active_90d) = 0 then 0 else sum(la.metric_c_last_active_90d) / sum(la.volume_last_active_90d) * 100 end as margin_last_active_90d
                        FROM totals_last_active_90d la
                        JOIN totals_last_90d l ON la.user_no = l.user_no AND la.entity_group = l.entity_group
                        group by la.entity_group, la.user_no, la.factor_x
        )
      SELECT /*+ materialize PARALLEL (8) optimizer_features_enable('19.1.0.0') */
               a.user_no, a.entity_group
             , to_date(a.time_key,'yyyymmdd') last_active_date
             , a.kambi_category_w, a.depositor
             , f.metric_a_last_90d, f.metric_b_last_90d, f.metric_bonus_last_90d
             , f.metric_c_last_90d, f.bonus_pct_last_90d
             , f.metric_a_last_active_90d, f.metric_b_last_active_90d
             , f.metric_bonus_last_active_90d, f.metric_c_last_active_90d
             , f.bonus_pct_last_active_90d, a.source_table, f.factor_x
             , f.margin_last_active_90d
             , CASE WHEN (p.category_type LIKE 'Category%' OR p.category_type='Multi-Category') THEN 1 ELSE 0 END as flag_c
             , cvs.most_frequent_segment, cvs.days_on_frequent_segment
        from entities_active_last_90d a
   left join aggregated_metrics f on f.user_no = a.user_no and f.entity_group = a.entity_group
   left join schema_analytics.entity_category_daily p on a.user_no = p.user_no and a.entity_group = p.entity_group
   left join most_common_segments cvs on f.user_no = cvs.user_no and f.entity_group = cvs.entity_group;

      COMMIT;
      log_time_taken(l_ref_date,'step_calculate_metrics', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_calculate_tier_level');
      select sysdate into l_start from dual;

      UPDATE schema_analytics.tmp_tracking_live_data a
         SET a.tier_level = schema_analytics.customer_segmentation_engine.calculate_tier_level(
                                p_source_table => a.source_table, p_depositor => a.depositor,
                                p_flag_b => a.kambi_category_w,
                                p_metric_a_90d => a.metric_a_last_90d, p_metric_b_90d => a.metric_b_last_90d,
                                p_flag_c => a.flag_c, p_metric_c_90d => a.metric_c_last_90d,
                                p_factor_x => a.factor_x);
      COMMIT;
      log_time_taken(l_ref_date,'step_calculate_tier_level', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_identify_tier_entities');
      select sysdate into l_start from dual;

      UPDATE schema_analytics.tmp_tracking_live_data a
         SET a.segment_value = schema_analytics.customer_segmentation_engine.get_tier_users(
                                p_source_table => a.source_table, p_depositor => a.depositor,
                                p_flag_b => a.kambi_category_w,
                                p_metric_a_90d => a.metric_a_last_90d, p_metric_b_90d => a.metric_b_last_90d,
                                p_flag_c => a.flag_c, p_factor_x => a.factor_x,
                                p_metric_c_90d => a.metric_c_last_90d);
      COMMIT;
      log_time_taken(l_ref_date,'step_identify_tier_entities', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_calculate_segments');
      select sysdate into l_start from dual;

      UPDATE schema_analytics.tmp_tracking_live_data a
         SET a.segment_value = schema_analytics.customer_segmentation_engine.calculate_segment(
                                p_source_table => a.source_table, p_depositor => a.depositor,
                                p_metric_a_active_90d => a.metric_a_last_active_90d,
                                p_metric_b_active_90d => a.metric_b_last_active_90d,
                                p_metric_c_active_90d => a.metric_c_last_active_90d)
       WHERE a.segment_value IS NULL;
      COMMIT;
      log_time_taken(l_ref_date,'step_calculate_tier_level_special', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_apply_tier_level_special');
      select sysdate into l_start from dual;

      UPDATE schema_analytics.tmp_tracking_live_data a
         SET a.tier_level = 6
       WHERE a.segment_value = 'SEG_B'
         AND a.metric_c_last_90d >= [THRESHOLD_SPECIAL];
      COMMIT;
      log_time_taken(l_ref_date,'step_calculate_segments', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_calculate_historical_max');
      select sysdate into l_start from dual;

      UPDATE schema_analytics.tmp_tracking_live_data a
         SET (a.highest_segment, a.highest_tier_level) = (
               SELECT least(nvl(b.highest_segment,'SEG_F'), NVL(a.segment_value,'SEG_F'))
                    , CASE WHEN (least(nvl(b.highest_tier_level, l_default_tier_level), NVL(a.tier_level, l_default_tier_level))) = l_default_tier_level THEN NULL
                           ELSE least(nvl(b.highest_tier_level, l_default_tier_level), NVL(a.tier_level, l_default_tier_level)) END
                 FROM schema_analytics.tracking_live_data b
                WHERE a.user_no = b.user_no AND a.entity_group = b.entity_group);
      COMMIT;

      UPDATE schema_analytics.tmp_tracking_live_data a
            SET (a.highest_segment, a.highest_tier_level) = (
                  SELECT b.segment_value, b.tier_level
                    FROM schema_analytics.tmp_tracking_live_data b
                   WHERE a.user_no = b.user_no AND a.entity_group = b.entity_group)
      WHERE a.user_no || a.entity_group NOT IN (SELECT user_no || entity_group from schema_analytics.tracking_live_data);
      COMMIT;
      log_time_taken(l_ref_date,'step_calculate_historical_max', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process ' || l_ref_date,
                                       action_name => 'step_merge_live_data');

      merge into schema_analytics.tracking_live_data o
      using schema_analytics.tmp_tracking_live_data n
      on (o.user_no = n.user_no and o.entity_group = n.entity_group)
      when matched then
        update set
           o.segment_value            = n.segment_value,
           o.tier_level               = n.tier_level,
           o.depositor                = n.depositor,
           o.kambi_category_w         = n.kambi_category_w,
           o.valid_from               = CASE WHEN (NVL(o.segment_value,'new') <> NVL(n.segment_value,'new') OR NVL(o.tier_level,-1) <> NVL(n.tier_level,-1)) THEN l_ref_date ELSE o.valid_from END,
           o.last_active_date         = n.last_active_date,
           o.updated                  = sysdate,
           o.metric_c_last_active_90  = CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_c_last_90d     ELSE n.metric_c_last_active_90d     END,
           o.metric_a_last_active_90  = CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_a_last_90d     ELSE n.metric_a_last_active_90d     END,
           o.metric_b_last_active_90  = CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_b_last_90d     ELSE n.metric_b_last_active_90d     END,
           o.metric_bonus_last_active_90 = CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_bonus_last_90d ELSE n.metric_bonus_last_active_90d END,
           o.bonus_spend_pct          = CASE WHEN n.segment_value = 'TIER_1' THEN n.bonus_pct_last_90d    ELSE n.bonus_pct_last_active_90d    END,
           o.highest_segment          = n.highest_segment,
           o.highest_tier_level       = n.highest_tier_level,
           o.most_frequent_segment    = CASE WHEN COALESCE(o.most_frequent_segment,'new') <> coalesce(n.most_frequent_segment,'new') THEN n.most_frequent_segment ELSE o.most_frequent_segment END,
           o.days_on_frequent_segment = CASE WHEN COALESCE(o.days_on_frequent_segment,-1) <> coalesce(n.days_on_frequent_segment,-1) THEN n.days_on_frequent_segment ELSE o.days_on_frequent_segment END,
           o.last_tier1_date          = CASE WHEN (coalesce(o.segment_value,'new') = 'TIER_1' AND coalesce(o.segment_value,'new') <> coalesce(n.segment_value,'new')) THEN l_ref_date - 1
                                             WHEN (coalesce(n.segment_value,'new') = 'TIER_1' AND coalesce(o.segment_value,'new') <> coalesce(n.segment_value,'new')) THEN l_max_date
                                             WHEN (coalesce(n.segment_value,'new') = 'TIER_1' AND coalesce(o.segment_value,'new') = coalesce(n.segment_value,'new')) THEN l_max_date
                                             ELSE o.last_tier1_date END
      when not matched then
        insert(o.user_no, o.entity_group, o.segment_value, o.tier_level, o.depositor, o.kambi_category_w,
               o.valid_from, o.last_active_date, o.inserted, o.updated,
               o.metric_c_last_active_90, o.metric_a_last_active_90, o.metric_b_last_active_90,
               o.metric_bonus_last_active_90, o.bonus_spend_pct,
               o.highest_segment, o.highest_tier_level,
               o.most_frequent_segment, o.days_on_frequent_segment, o.last_tier1_date)
        values
          (n.user_no, n.entity_group, n.segment_value, n.tier_level, n.depositor, n.kambi_category_w,
           l_ref_date, n.last_active_date, sysdate, sysdate,
           CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_c_last_90d     ELSE n.metric_c_last_active_90d     END,
           CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_a_last_90d     ELSE n.metric_a_last_active_90d     END,
           CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_b_last_90d     ELSE n.metric_b_last_active_90d     END,
           CASE WHEN n.segment_value = 'TIER_1' THEN n.metric_bonus_last_90d ELSE n.metric_bonus_last_active_90d END,
           CASE WHEN n.segment_value = 'TIER_1' THEN n.bonus_pct_last_90d    ELSE n.bonus_pct_last_active_90d    END,
           n.highest_segment, n.highest_tier_level,
           n.most_frequent_segment, n.days_on_frequent_segment,
           CASE WHEN n.segment_value = 'TIER_1' THEN l_max_date ELSE NULL END);

      commit;

      UPDATE schema_analytics.tracking_live_data a
         SET a.tier_level = NULL
           , valid_from   = l_ref_date
           , updated      = sysdate
       WHERE a.last_active_date < l_ref_date - 90
         and a.tier_level is not null
         and a.entity_group in (select entity_group from schema_dim.entity_groups where active='Y');
      commit;
      log_time_taken(l_ref_date,'step_merge_live_data', l_start, sysdate);

      dbms_application_info.set_module(module_name => 'Segmentation_Process', action_name => 'step_complete');

  exception
    when others then
      rollback;
      p_message := SQLERRM;
  end run_refresh_daily;

end customer_segmentation_engine;
/
