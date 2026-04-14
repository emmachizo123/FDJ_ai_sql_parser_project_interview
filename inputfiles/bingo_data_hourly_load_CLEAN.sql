CREATE OR REPLACE PACKAGE BODY SCHEMA_ETL.PKG_API_DATA_LOADER AS

c_module_name CONSTANT VARCHAR2(256) := 'API_DATA_LOADER';
c_config_module CONSTANT VARCHAR2(256) := 'API_CONFIGURATION_LOADER';
c_error_log_table CONSTANT VARCHAR2(50) := 'SCHEMA_AUDIT.ERROR_LOG_TABLE';

-- [ORIGINAL APPROACH] API Configuration
c_environment VARCHAR2(100);
c_api_username VARCHAR2(256);
c_api_password VARCHAR2(256);
c_api_base_url VARCHAR2(256);
c_endpoint_users VARCHAR2(256);
c_endpoint_aggregates VARCHAR2(256);
c_endpoint_transactions VARCHAR2(256);
c_endpoint_rewards VARCHAR2(256);
c_endpoint_config VARCHAR2(256);

-- [NEW APPROACH] Bronze Layer table names
c_bronze_schema VARCHAR2(100) := 'BRONZE';
c_bronze_users_table VARCHAR2(256) := 'USERS_BRONZE';
c_bronze_aggregates_table VARCHAR2(256) := 'AGGREGATES_BRONZE';
c_bronze_transactions_table VARCHAR2(256) := 'TRANSACTIONS_BRONZE';
c_bronze_prizes_table VARCHAR2(256) := 'TRANSACTION_PRIZES_BRONZE';
c_bronze_progressive_prizes_table VARCHAR2(256) := 'PROGRESSIVE_PRIZES_BRONZE';

g_debug_mode NUMBER := 1;

-- ============================================================
-- SECTION 1: ORIGINAL APPROACH – API DATA EXTRACTION
-- ============================================================

FUNCTION Fetch_API_XML(
  p_endpoint    VARCHAR2,
  p_request_url VARCHAR2,
  p_request_date DATE
) RETURN XMLTYPE IS
  lt_header_names  SCHEMA_ETL.HTTP_UTILS.char100_tab;
  lt_header_values SCHEMA_ETL.HTTP_UTILS.char1000_tab;
  l_response_clob  CLOB;
  l_xml_data       XMLTYPE;
  l_date_regional_tz DATE;
BEGIN
  SCHEMA_ETL.HTTP_UTILS.apply_mozilla_settings;
  IF NVL(c_environment, 'TEST') <> 'PROD' THEN
    UTL_HTTP.set_proxy(NULL, NULL);
  END IF;
  lt_header_names(1)  := 'Content-Type';
  lt_header_values(1) := 'application/x-www-form-urlencoded';
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Fetch_API_XML() Request URL=%1', LOG_PKG.build_params(p_request_url));
  l_response_clob := SCHEMA_ETL.HTTP_UTILS.Get_Server_Response(
    p_request_url, lt_header_names, lt_header_values,
    'GET', NULL, c_api_username, c_api_password);
  l_response_clob :=
    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
    l_response_clob,
    '<progressiveconfig/>', ''), '<totals/>', ''), '<partnertotals/>', ''),
    '<prizes/>', ''), '<progressiveprizes/>', ''), '<transactions/>', '');
  l_xml_data := XMLTYPE(l_response_clob);
  IF g_debug_mode = 1 THEN
    l_date_regional_tz := SCHEMA_ETL.fn_convert_timezone('UTC', 'TZ_REGION', p_request_date);
    DELETE FROM SCHEMA_ETL.DEBUG_API_RESPONSES
     WHERE ref_date = TRUNC(l_date_regional_tz)
       AND ref_hour = TO_CHAR(l_date_regional_tz, 'HH24')
       AND api_endpoint = p_endpoint;
    INSERT INTO SCHEMA_ETL.DEBUG_API_RESPONSES(
      ref_date, ref_date_hour, request_timestamp_tz, request_timestamp_utc,
      api_endpoint, request_url, response_xml)
    VALUES (
      TRUNC(l_date_regional_tz), TO_CHAR(l_date_regional_tz, 'HH24'),
      l_date_regional_tz, p_request_date, p_endpoint,
      SUBSTR(p_request_url, 0, 4000), l_response_clob);
    COMMIT;
  END IF;
  RETURN l_xml_data;
EXCEPTION
  WHEN OTHERS THEN
    LOG_PKG.log_error(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
      'Fetch_API_XML() error. Response excerpt=' || DBMS_LOB.SUBSTR(l_response_clob, 256, 1), SQLERRM);
    RAISE;
END Fetch_API_XML;

PROCEDURE Extract_Users_From_API(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
  l_current_date DATE := p_start_date;
  l_xml_data     XMLTYPE;
  l_request_url  VARCHAR2(4000);
  l_hour_string  VARCHAR2(10);
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_USERS';
  WHILE l_current_date < p_end_date LOOP
    l_hour_string := TO_CHAR(l_current_date, 'HH24');
    LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
      'Extract_Users_From_API() Processing date=%1 (UTC)',
      LOG_PKG.build_params(TO_CHAR(l_current_date, 'DD/MM/YYYY HH24:MI:SS')));
    l_request_url := c_api_base_url || c_endpoint_users ||
      '?date=' || TO_CHAR(l_current_date, 'YYYY-MM-DD') ||
      '&starthour=' || l_hour_string;
    l_xml_data := Fetch_API_XML(c_endpoint_users, l_request_url, l_current_date);
    LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
      'Parsing user XML for date=%1 (UTC)',
      LOG_PKG.build_params(TO_CHAR(l_current_date, 'DD/MM/YYYY HH24:MI:SS')));
    Stage_User_Data(l_xml_data, l_current_date);
    l_current_date := l_current_date + 1/24;
  END LOOP;
END Extract_Users_From_API;

PROCEDURE Stage_User_Data(
  p_xml  XMLTYPE,
  p_date DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_USERS (
    external_user_id, internal_user_id, brand_code,
    registration_timestamp_utc, registration_timestamp_regional,
    registration_channel, registration_client_id, user_currency)
  SELECT
    u.external_user_id, u.internal_user_id, u.brand_code,
    TO_DATE(u.registration_timestamp, 'YYYY-MM-DD HH24:MI:SS'),
    SCHEMA_ETL.fn_convert_timezone('UTC', 'TZ_REGION',
      TO_DATE(u.registration_timestamp, 'YYYY-MM-DD HH24:MI:SS')),
    u.registration_channel, u.registration_client_id,
    LOWER(u.currency_code)
  FROM (SELECT p_xml AS xml_data FROM dual) x,
  XMLTABLE('/registrations/users/user'
    PASSING x.xml_data
    COLUMNS
      external_user_id       NUMBER        PATH 'externalid',
      internal_user_id       NUMBER        PATH 'internalid',
      brand_code             VARCHAR2(4000) PATH 'brand',
      registration_timestamp VARCHAR2(100)  PATH 'registrationtime',
      registration_channel   VARCHAR2(4000) PATH 'channel',
      registration_client_id VARCHAR2(4000) PATH 'clientid',
      currency_code          VARCHAR2(4000) PATH 'currency'
  ) u;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' users staged');
END Stage_User_Data;

PROCEDURE Extract_Aggregates_From_API(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
  l_current_date DATE := p_start_date;
  l_xml_data     XMLTYPE;
  l_request_url  VARCHAR2(4000);
  l_hour_string  VARCHAR2(10);
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_AGGREGATES';
  WHILE l_current_date < p_end_date LOOP
    l_hour_string := TO_CHAR(l_current_date, 'HH24');
    LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
      'Extract_Aggregates_From_API() Processing date=%1 (UTC)',
      LOG_PKG.build_params(TO_CHAR(l_current_date, 'DD/MM/YYYY HH24:MI:SS')));
    l_request_url := c_api_base_url || c_endpoint_aggregates ||
      '?date=' || TO_CHAR(l_current_date, 'YYYY-MM-DD') ||
      '&starthour=' || l_hour_string;
    l_xml_data := Fetch_API_XML(c_endpoint_aggregates, l_request_url, l_current_date);
    LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
      'Parsing aggregate XML for date=%1 (UTC)',
      LOG_PKG.build_params(TO_CHAR(l_current_date, 'DD/MM/YYYY HH24:MI:SS')));
    Stage_Aggregate_Data(l_xml_data, l_current_date);
    l_current_date := l_current_date + 1/24;
  END LOOP;
END Extract_Aggregates_From_API;

PROCEDURE Stage_Aggregate_Data(
  p_xml  XMLTYPE,
  p_date DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_AGGREGATES (
    session_id, location_id, template_id, template_name, session_name,
    start_timestamp, end_timestamp, base_currency, variant_type,
    call_rate, unit_price, guarantee_amount, added_amount, guarantee_met_flag, called_numbers,
    progressive_id, progressive_type, progressive_seed, progressive_percentage,
    total_participants, total_cash_units, total_voucher_units, total_free_units,
    total_cash_bets, total_exact_cash_bets, total_cash_contribution,
    total_exact_cash_contribution, total_voucher_bets, total_exact_voucher_bets,
    total_cash_payouts, total_voucher_payouts, total_progressive_cash_contrib,
    total_progressive_voucher_contrib, total_progressive_id,
    total_progressive_cash_payout, total_progressive_voucher_payout,
    partner_participants, partner_cash_units, partner_voucher_units, partner_free_units,
    partner_cash_bets, partner_exact_cash_bets, partner_cash_contribution,
    partner_exact_cash_contribution, partner_voucher_bets, partner_exact_voucher_bets,
    partner_cash_payouts, partner_voucher_payouts, partner_progressive_cash_contrib,
    partner_progressive_voucher_contrib, partner_progressive_id,
    partner_progressive_cash_payout, partner_progressive_voucher_payout)
  SELECT
    session_id, location_id, template_id, template_name, session_name,
    start_timestamp, end_timestamp, base_currency, variant_type, call_rate,
    unit_price, guarantee_amount, added_amount, guarantee_met_flag, called_numbers,
    progressive_id, progressive_type, progressive_seed, progressive_percentage,
    total_participants, total_cash_units, total_voucher_units, total_free_units,
    total_cash_bets, total_exact_cash_bets, total_cash_contribution,
    total_exact_cash_contribution, total_voucher_bets, total_exact_voucher_bets,
    total_cash_payouts, total_voucher_payouts, total_progressive_cash_contrib,
    total_progressive_voucher_contrib, total_progressive_id,
    total_progressive_cash_payout, total_progressive_voucher_payout,
    partner_participants, partner_cash_units, partner_voucher_units, partner_free_units,
    partner_cash_bets, partner_exact_cash_bets, partner_cash_contribution,
    partner_exact_cash_contribution, partner_voucher_bets, partner_exact_voucher_bets,
    partner_cash_payouts, partner_voucher_payouts, partner_progressive_cash_contrib,
    partner_progressive_voucher_contrib, partner_progressive_id,
    partner_progressive_cash_payout, partner_progressive_voucher_payout
  FROM (SELECT p_xml AS xml_data FROM dual) y,
  XMLTABLE('/sessions/session' PASSING y.xml_data
    COLUMNS
      session_id         NUMBER        PATH 'sessionid',
      location_id        NUMBER        PATH 'locationid',
      template_id        NUMBER        PATH 'templateid',
      template_name      VARCHAR2(100) PATH 'templatename',
      session_name       VARCHAR2(100) PATH 'name',
      start_timestamp    VARCHAR2(100) PATH 'start',
      end_timestamp      VARCHAR2(100) PATH 'end',
      base_currency      VARCHAR2(100) PATH 'basecurrency',
      variant_type       VARCHAR2(100) PATH 'variant',
      call_rate          NUMBER        PATH 'callrate',
      unit_price         NUMBER        PATH 'unitprice',
      guarantee_amount   NUMBER        PATH 'guarantee',
      added_amount       NUMBER        PATH 'added',
      guarantee_met_flag VARCHAR2(100) PATH 'guaranteemet',
      called_numbers     VARCHAR2(100) PATH 'callednumbers',
      progressive_config XMLTYPE       PATH 'progressiveconfig/progressive',
      totals_node        XMLTYPE       PATH 'totals',
      partner_totals_node XMLTYPE      PATH 'partnertotals'
  ) agg,
  XMLTABLE('/progressive' PASSING agg.progressive_config
    COLUMNS
      progressive_id         NUMBER        PATH 'progressiveid',
      progressive_type       VARCHAR2(100) PATH 'type',
      progressive_seed       NUMBER        PATH 'seed',
      progressive_percentage NUMBER        PATH 'percentage'
  ) prog,
  XMLTABLE('/totals' PASSING agg.totals_node
    COLUMNS
      total_participants          NUMBER  PATH 'participants',
      total_cash_units            NUMBER  PATH 'cashunits',
      total_voucher_units         NUMBER  PATH 'voucherunits',
      total_free_units            NUMBER  PATH 'freeunits',
      total_cash_bets             NUMBER  PATH 'cashbets',
      total_exact_cash_bets       NUMBER  PATH 'exactcashbets',
      total_cash_contribution     NUMBER  PATH 'cashcontribution',
      total_exact_cash_contribution NUMBER PATH 'exactcashcontribution',
      total_voucher_bets          NUMBER  PATH 'voucherbets',
      total_exact_voucher_bets    NUMBER  PATH 'exactvoucherbets',
      total_cash_payouts          NUMBER  PATH 'cashpayouts',
      total_voucher_payouts       NUMBER  PATH 'voucherpayouts',
      progressive_contributions   XMLTYPE PATH 'progressivecontributions/progressive',
      progressive_payouts         XMLTYPE PATH 'progressivepayouts/progressive'
  ) tot,
  XMLTABLE('/progressive' PASSING tot.progressive_contributions
    COLUMNS
      total_progressive_cash_contrib    NUMBER PATH 'cashcontribution',
      total_progressive_voucher_contrib NUMBER PATH 'vouchercontribution'
  ) prog_contrib,
  XMLTABLE('/progressive' PASSING tot.progressive_payouts
    COLUMNS
      total_progressive_id            NUMBER PATH 'progressiveid',
      total_progressive_cash_payout   NUMBER PATH 'cashpayout',
      total_progressive_voucher_payout NUMBER PATH 'voucherpayout'
  ) prog_payout,
  XMLTABLE('/partnertotals' PASSING agg.partner_totals_node
    COLUMNS
      partner_participants            NUMBER  PATH 'participants',
      partner_cash_units              NUMBER  PATH 'cashunits',
      partner_voucher_units           NUMBER  PATH 'voucherunits',
      partner_free_units              NUMBER  PATH 'freeunits',
      partner_cash_bets               NUMBER  PATH 'cashbets',
      partner_exact_cash_bets         NUMBER  PATH 'exactcashbets',
      partner_cash_contribution       NUMBER  PATH 'cashcontribution',
      partner_exact_cash_contribution NUMBER  PATH 'exactcashcontribution',
      partner_voucher_bets            NUMBER  PATH 'voucherbets',
      partner_exact_voucher_bets      NUMBER  PATH 'exactvoucherbets',
      partner_cash_payouts            NUMBER  PATH 'cashpayouts',
      partner_voucher_payouts         NUMBER  PATH 'voucherpayouts',
      partner_progressive_contribs    XMLTYPE PATH 'progressivecontributions/progressive',
      partner_progressive_payouts     XMLTYPE PATH 'progressivepayouts/progressive'
  ) pt,
  XMLTABLE('/progressive' PASSING pt.partner_progressive_contribs
    COLUMNS
      partner_progressive_cash_contrib    NUMBER PATH 'cashcontribution',
      partner_progressive_voucher_contrib NUMBER PATH 'vouchercontribution'
  ) pt_contrib,
  XMLTABLE('/progressive' PASSING pt.partner_progressive_payouts
    COLUMNS
      partner_progressive_id             NUMBER PATH 'progressiveid',
      partner_progressive_cash_payout    NUMBER PATH 'cashpayout',
      partner_progressive_voucher_payout NUMBER PATH 'voucherpayout'
  ) pt_payout;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' aggregate records staged');
  COMMIT;
END Stage_Aggregate_Data;

PROCEDURE Extract_Transactions_From_API(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
  l_current_date DATE := p_start_date;
  l_xml_data     XMLTYPE;
  l_request_url  VARCHAR2(4000);
  l_hour_string  VARCHAR2(10);
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTIONS';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTION_PRIZES';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_PROGRESSIVE_PRIZES';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTION_SUMMARY';
  WHILE l_current_date < p_end_date LOOP
    l_hour_string := TO_CHAR(l_current_date, 'HH24');
    l_request_url := c_api_base_url || c_endpoint_transactions ||
      '?date=' || TO_CHAR(l_current_date, 'YYYY-MM-DD') ||
      '&starthour=' || l_hour_string;
    l_xml_data := Fetch_API_XML(c_endpoint_transactions, l_request_url, l_current_date);
    Stage_Transaction_Data(l_xml_data, l_current_date);
    l_current_date := l_current_date + 1/24;
  END LOOP;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Aggregating transaction data from 3 staging tables');
  Aggregate_Transaction_Summary(p_start_date, p_end_date);
END Extract_Transactions_From_API;

PROCEDURE Stage_Transaction_Data(
  p_xml  XMLTYPE,
  p_date DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_TRANSACTIONS (
    session_id, external_user_id, internal_user_id,
    transaction_timestamp, transaction_id, channel_code, client_id,
    cash_units_count, voucher_units_count, free_units_count,
    currency_code, cash_bet_amount, voucher_bet_amount,
    cash_contribution, voucher_contribution, voucher_id,
    progressive_id, progressive_cash_contrib, progressive_voucher_contrib)
  SELECT
    agg.session_id, u.external_user_id, u.internal_user_id,
    trans.transaction_timestamp, trans.transaction_id,
    trans.channel_code, trans.client_id,
    trans.cash_units_count, trans.voucher_units_count, trans.free_units_count,
    trans.currency_code, trans.cash_bet_amount, trans.voucher_bet_amount,
    trans.cash_contribution, trans.voucher_contribution, trans.voucher_id,
    prog_contrib.progressive_id, prog_contrib.progressive_cash_contrib,
    prog_contrib.progressive_voucher_contrib
  FROM (SELECT p_xml FROM dual) x,
  XMLTABLE('/sessions/session' PASSING x.p_xml
    COLUMNS session_id NUMBER PATH 'sessionid', users_node XMLTYPE PATH 'partnerusers/user') agg,
  XMLTABLE('/user' PASSING agg.users_node
    COLUMNS
      external_user_id NUMBER PATH 'externalid',
      internal_user_id NUMBER PATH 'internalid',
      transactions_node XMLTYPE PATH 'transactions/transaction',
      prizes_node       XMLTYPE PATH 'prizes/prize',
      progressive_prizes XMLTYPE PATH 'progressiveprizes/progressiveprize') u,
  XMLTABLE('/transaction' PASSING u.transactions_node
    COLUMNS
      transaction_id        NUMBER        PATH 'transactionid',
      transaction_timestamp VARCHAR2(100) PATH 'timestamp',
      channel_code          VARCHAR2(100) PATH 'channel',
      client_id             VARCHAR2(100) PATH 'clientid',
      cash_units_count      NUMBER        PATH 'cashunits',
      voucher_units_count   NUMBER        PATH 'voucherunits',
      free_units_count      NUMBER        PATH 'freeunits',
      currency_code         VARCHAR2(100) PATH 'currency',
      cash_bet_amount       NUMBER        PATH 'cashbets',
      cash_contribution     NUMBER        PATH 'cashcontribution',
      voucher_bet_amount    NUMBER        PATH 'voucherbets',
      voucher_id            NUMBER        PATH 'voucherid',
      voucher_contribution  NUMBER        PATH 'vouchercontribution',
      progressive_contributions XMLTYPE PATH 'progressivecontributions/progressive') trans,
  XMLTABLE('/progressive' PASSING trans.progressive_contributions
    COLUMNS
      progressive_id             NUMBER PATH 'progressiveid',
      progressive_cash_contrib   NUMBER PATH 'cashcontribution',
      progressive_voucher_contrib NUMBER PATH 'vouchercontribution') prog_contrib;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_TRANSACTIONS');

  INSERT INTO SCHEMA_ETL.STG_TRANSACTION_PRIZES (
    session_id, external_user_id, internal_user_id, prize_amount, prize_payout_type)
  SELECT agg.session_id, u.external_user_id, u.internal_user_id,
    prize.prize_amount, prize.prize_payout_type
  FROM (SELECT p_xml FROM dual) x,
  XMLTABLE('/sessions/session' PASSING x.p_xml
    COLUMNS session_id NUMBER PATH 'sessionid', users_node XMLTYPE PATH 'partnerusers/user') agg,
  XMLTABLE('/user' PASSING agg.users_node
    COLUMNS external_user_id NUMBER PATH 'externalid', internal_user_id NUMBER PATH 'internalid',
    prizes_node XMLTYPE PATH 'prizes/prize') u,
  XMLTABLE('/prize' PASSING u.prizes_node
    COLUMNS prize_amount NUMBER PATH 'amount', prize_payout_type VARCHAR2(100) PATH 'payouttype') prize;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_TRANSACTION_PRIZES');

  INSERT INTO SCHEMA_ETL.STG_PROGRESSIVE_PRIZES (
    session_id, external_user_id, internal_user_id,
    progressive_payout_amount, progressive_payout_type,
    progressive_payout_id, progressive_cashier_id,
    max_progressive_amount, progressive_prize_id)
  SELECT agg.session_id, u.external_user_id, u.internal_user_id,
    prog_prize.payout_amount, prog_prize.payout_type,
    prog_prize.payout_id, prog_prize.cashier_id,
    prog_prize.max_progressive, prog_prize.prize_id
  FROM (SELECT p_xml FROM dual) x,
  XMLTABLE('/sessions/session' PASSING x.p_xml
    COLUMNS session_id NUMBER PATH 'sessionid', users_node XMLTYPE PATH 'partnerusers/user') agg,
  XMLTABLE('/user' PASSING agg.users_node
    COLUMNS external_user_id NUMBER PATH 'externalid', internal_user_id NUMBER PATH 'internalid',
    progressive_prizes XMLTYPE PATH 'progressiveprizes/progressiveprize') u,
  XMLTABLE('/progressiveprize' PASSING u.progressive_prizes
    COLUMNS
      payout_id       NUMBER        PATH 'progressiveid',
      payout_amount   NUMBER        PATH 'amount',
      payout_type     VARCHAR2(100) PATH 'payouttype',
      max_progressive NUMBER        PATH 'maxprogressive',
      prize_id        NUMBER        PATH 'prizeid',
      cashier_id      VARCHAR2(10)  PATH 'cashierid') prog_prize;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_PROGRESSIVE_PRIZES');
  COMMIT;
END Stage_Transaction_Data;

PROCEDURE Merge_Aggregates_To_Target(
  p_date_from DATE,
  p_date_to   DATE
) IS
BEGIN
  MERGE INTO SCHEMA_ETL.FACT_AGGREGATES tgt
  USING (
    SELECT DISTINCT
      session_id, location_id, template_id, template_name, session_name,
      TO_DATE(start_timestamp, 'YYYY-MM-DD HH24:MI:SS') AS start_timestamp_utc,
      SCHEMA_ETL.fn_convert_timezone('UTC', 'TZ_REGION',
        TO_DATE(start_timestamp, 'YYYY-MM-DD HH24:MI:SS')) AS start_timestamp_regional,
      TO_DATE(end_timestamp, 'YYYY-MM-DD HH24:MI:SS') AS end_timestamp_utc,
      SCHEMA_ETL.fn_convert_timezone('UTC', 'TZ_REGION',
        TO_DATE(end_timestamp, 'YYYY-MM-DD HH24:MI:SS')) AS end_timestamp_regional,
      base_currency, variant_type, call_rate, unit_price,
      guarantee_amount, added_amount, guarantee_met_flag, called_numbers,
      progressive_id, progressive_type,
      CASE WHEN progressive_type = 'fixed'    THEN NVL(progressive_seed, 0) END AS fixed_progressive_seed,
      CASE WHEN progressive_type = 'variable' THEN NVL(progressive_seed, 0) END AS variable_progressive_seed,
      progressive_percentage,
      total_participants, total_cash_units, total_voucher_units, total_free_units,
      total_cash_bets, total_exact_cash_bets, total_cash_contribution,
      total_exact_cash_contribution, total_voucher_bets, total_exact_voucher_bets,
      total_cash_payouts, total_voucher_payouts, total_progressive_cash_contrib,
      total_progressive_voucher_contrib, total_progressive_id,
      total_progressive_cash_payout, total_progressive_voucher_payout,
      partner_participants, partner_cash_units, partner_voucher_units, partner_free_units,
      partner_cash_bets, partner_exact_cash_bets, partner_cash_contribution,
      partner_exact_cash_contribution, partner_voucher_bets, partner_exact_voucher_bets,
      partner_cash_payouts, partner_voucher_payouts, partner_progressive_cash_contrib,
      partner_progressive_voucher_contrib, partner_progressive_id,
      partner_progressive_cash_payout, partner_progressive_voucher_payout
    FROM SCHEMA_ETL.STG_AGGREGATES
  ) src
  ON (tgt.session_id = src.session_id AND NVL(tgt.progressive_id, 0) = NVL(src.progressive_id, 0))
  WHEN MATCHED THEN UPDATE SET
    tgt.fixed_progressive_seed   = src.fixed_progressive_seed,
    tgt.variable_progressive_seed = src.variable_progressive_seed,
    tgt.progressive_percentage   = src.progressive_percentage,
    tgt.total_participants       = src.total_participants,
    tgt.total_cash_units         = src.total_cash_units,
    tgt.partner_progressive_voucher_payout = src.partner_progressive_voucher_payout
  WHEN NOT MATCHED THEN INSERT (
    session_id, location_id, template_id, template_name, session_name,
    start_timestamp_utc, start_timestamp_regional, end_timestamp_utc, end_timestamp_regional,
    base_currency, variant_type, call_rate, unit_price,
    guarantee_amount, added_amount, guarantee_met_flag, called_numbers,
    progressive_id, progressive_type, fixed_progressive_seed, variable_progressive_seed,
    progressive_percentage, total_participants, partner_progressive_voucher_payout,
    dwh_insert_timestamp)
  VALUES (
    src.session_id, src.location_id, src.template_id, src.template_name, src.session_name,
    src.start_timestamp_utc, src.start_timestamp_regional,
    src.end_timestamp_utc, src.end_timestamp_regional,
    src.base_currency, src.variant_type, src.call_rate, src.unit_price,
    src.guarantee_amount, src.added_amount, src.guarantee_met_flag, src.called_numbers,
    src.progressive_id, src.progressive_type,
    src.fixed_progressive_seed, src.variable_progressive_seed, src.progressive_percentage,
    src.total_participants, src.partner_progressive_voucher_payout, SYSDATE);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' records merged into FACT_AGGREGATES');
END Merge_Aggregates_To_Target;

-- ============================================================
-- SECTION 2: NEW APPROACH – BRONZE LAYER SOURCE
-- ============================================================

PROCEDURE Extract_Users_From_Bronze(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_USERS';
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Extract_Users_From_Bronze() Processing date range: %1 to %2 (UTC)',
    LOG_PKG.build_params(TO_CHAR(p_start_date, 'DD/MM/YYYY HH24:MI:SS') || ' - ' ||
    TO_CHAR(p_end_date, 'DD/MM/YYYY HH24:MI:SS')));
  Stage_User_Data_From_Bronze(p_start_date, p_end_date);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Extract_Users_From_Bronze() completed');
END Extract_Users_From_Bronze;

PROCEDURE Stage_User_Data_From_Bronze(
  p_start_date DATE,
  p_end_date   DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_USERS (
    external_user_id, internal_user_id, brand_code,
    registration_timestamp_utc, registration_timestamp_regional,
    registration_channel, registration_client_id, user_currency)
  SELECT
    brz.external_user_id, brz.internal_user_id, brz.brand_code,
    brz.registration_timestamp_utc,
    SCHEMA_ETL.fn_convert_timezone('UTC', 'TZ_REGION', brz.registration_timestamp_utc),
    brz.registration_channel, brz.registration_client_id,
    LOWER(brz.currency_code)
  FROM BRONZE.USERS_BRONZE brz
  WHERE brz.registration_timestamp_utc >= p_start_date
    AND brz.registration_timestamp_utc <  p_end_date;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' users staged from bronze layer');
END Stage_User_Data_From_Bronze;

PROCEDURE Load_Users_To_Target(
  p_date_from DATE,
  p_date_to   DATE
) IS
BEGIN
  DELETE FROM SCHEMA_ETL.DIM_USERS
   WHERE registration_timestamp_utc >= p_date_from
     AND registration_timestamp_utc <  p_date_to;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' users deleted from target');
  INSERT INTO SCHEMA_ETL.DIM_USERS (
    external_user_id, internal_user_id, brand_code,
    registration_timestamp_utc, registration_timestamp_regional,
    registration_channel, registration_client_id, user_currency)
  SELECT
    external_user_id, internal_user_id, brand_code,
    registration_timestamp_utc, registration_timestamp_regional,
    registration_channel, registration_client_id, user_currency
  FROM SCHEMA_ETL.STG_USERS;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' users inserted into target');
END Load_Users_To_Target;

PROCEDURE Extract_Aggregates_From_Bronze(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_AGGREGATES';
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Extract_Aggregates_From_Bronze() Processing date range: %1 to %2 (UTC)',
    LOG_PKG.build_params(TO_CHAR(p_start_date, 'DD/MM/YYYY HH24:MI:SS') || ' - ' ||
    TO_CHAR(p_end_date, 'DD/MM/YYYY HH24:MI:SS')));
  Stage_Aggregate_Data_From_Bronze(p_start_date, p_end_date);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Extract_Aggregates_From_Bronze() completed');
END Extract_Aggregates_From_Bronze;

PROCEDURE Stage_Aggregate_Data_From_Bronze(
  p_start_date DATE,
  p_end_date   DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_AGGREGATES (
    session_id, location_id, template_id, template_name, session_name,
    start_timestamp, end_timestamp, base_currency, variant_type,
    call_rate, unit_price, guarantee_amount, added_amount, guarantee_met_flag, called_numbers,
    progressive_id, progressive_type, progressive_seed, progressive_percentage,
    total_participants, total_cash_units, total_voucher_units, total_free_units,
    total_cash_bets, total_exact_cash_bets, total_cash_contribution,
    total_exact_cash_contribution, total_voucher_bets, total_exact_voucher_bets,
    total_cash_payouts, total_voucher_payouts, total_progressive_cash_contrib,
    total_progressive_voucher_contrib, total_progressive_id,
    total_progressive_cash_payout, total_progressive_voucher_payout,
    partner_participants, partner_cash_units, partner_voucher_units, partner_free_units,
    partner_cash_bets, partner_exact_cash_bets, partner_cash_contribution,
    partner_exact_cash_contribution, partner_voucher_bets, partner_exact_voucher_bets,
    partner_cash_payouts, partner_voucher_payouts, partner_progressive_cash_contrib,
    partner_progressive_voucher_contrib, partner_progressive_id,
    partner_progressive_cash_payout, partner_progressive_voucher_payout)
  SELECT
    brz.session_id, brz.location_id, brz.template_id, brz.template_name, brz.session_name,
    brz.start_timestamp, brz.end_timestamp,
    brz.base_currency, brz.variant_type, brz.call_rate,
    brz.unit_price, brz.guarantee_amount, brz.added_amount, brz.guarantee_met_flag, brz.called_numbers,
    brz.progressive_id, brz.progressive_type, brz.progressive_seed, brz.progressive_percentage,
    brz.total_participants, brz.total_cash_units, brz.total_voucher_units, brz.total_free_units,
    brz.total_cash_bets, brz.total_exact_cash_bets, brz.total_cash_contribution,
    brz.total_exact_cash_contribution, brz.total_voucher_bets, brz.total_exact_voucher_bets,
    brz.total_cash_payouts, brz.total_voucher_payouts, brz.total_progressive_cash_contrib,
    brz.total_progressive_voucher_contrib, brz.total_progressive_id,
    brz.total_progressive_cash_payout, brz.total_progressive_voucher_payout,
    brz.partner_participants, brz.partner_cash_units, brz.partner_voucher_units, brz.partner_free_units,
    brz.partner_cash_bets, brz.partner_exact_cash_bets, brz.partner_cash_contribution,
    brz.partner_exact_cash_contribution, brz.partner_voucher_bets, brz.partner_exact_voucher_bets,
    brz.partner_cash_payouts, brz.partner_voucher_payouts, brz.partner_progressive_cash_contrib,
    brz.partner_progressive_voucher_contrib, brz.partner_progressive_id,
    brz.partner_progressive_cash_payout, brz.partner_progressive_voucher_payout
  FROM BRONZE.AGGREGATES_BRONZE brz
  WHERE brz.start_timestamp >= p_start_date
    AND brz.start_timestamp <  p_end_date;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' aggregate records staged from bronze layer');
  COMMIT;
END Stage_Aggregate_Data_From_Bronze;

PROCEDURE Extract_Transactions_From_Bronze(
  p_start_date IN DATE DEFAULT TRUNC(SYSDATE, 'HH') - 2/24,
  p_end_date   IN DATE DEFAULT TRUNC(SYSDATE, 'HH') + 1/24,
  p_debug      IN NUMBER DEFAULT 0
) IS
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTIONS';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTION_PRIZES';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_PROGRESSIVE_PRIZES';
  EXECUTE IMMEDIATE 'TRUNCATE TABLE SCHEMA_ETL.STG_TRANSACTION_SUMMARY';
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Extract_Transactions_From_Bronze() Processing date range: %1 to %2 (UTC)',
    LOG_PKG.build_params(TO_CHAR(p_start_date, 'DD/MM/YYYY HH24:MI:SS') || ' - ' ||
    TO_CHAR(p_end_date, 'DD/MM/YYYY HH24:MI:SS')));
  Stage_Transaction_Data_From_Bronze(p_start_date, p_end_date);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    'Aggregating transaction data from 3 staging tables');
  Aggregate_Transaction_Summary(p_start_date, p_end_date);
END Extract_Transactions_From_Bronze;

PROCEDURE Stage_Transaction_Data_From_Bronze(
  p_start_date DATE,
  p_end_date   DATE
) IS
BEGIN
  INSERT INTO SCHEMA_ETL.STG_TRANSACTIONS (
    session_id, external_user_id, internal_user_id,
    transaction_timestamp, transaction_id, channel_code, client_id,
    cash_units_count, voucher_units_count, free_units_count,
    currency_code, cash_bet_amount, voucher_bet_amount,
    cash_contribution, voucher_contribution, voucher_id,
    progressive_id, progressive_cash_contrib, progressive_voucher_contrib)
  SELECT
    brz.session_id, brz.external_user_id, brz.internal_user_id,
    brz.transaction_timestamp, brz.transaction_id,
    brz.channel_code, brz.client_id,
    brz.cash_units_count, brz.voucher_units_count, brz.free_units_count,
    brz.currency_code, brz.cash_bet_amount, brz.voucher_bet_amount,
    brz.cash_contribution, brz.voucher_contribution, brz.voucher_id,
    brz.progressive_id, brz.progressive_cash_contrib, brz.progressive_voucher_contrib
  FROM BRONZE.TRANSACTIONS_BRONZE brz
  WHERE brz.transaction_timestamp >= p_start_date
    AND brz.transaction_timestamp <  p_end_date;
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_TRANSACTIONS');

  INSERT INTO SCHEMA_ETL.STG_TRANSACTION_PRIZES (
    session_id, external_user_id, internal_user_id, prize_amount, prize_payout_type)
  SELECT brz.session_id, brz.external_user_id, brz.internal_user_id,
    brz.prize_amount, brz.prize_payout_type
  FROM BRONZE.TRANSACTION_PRIZES_BRONZE brz
  WHERE EXISTS (
    SELECT 1 FROM SCHEMA_ETL.STG_TRANSACTIONS stg
     WHERE stg.session_id = brz.session_id
       AND stg.external_user_id = brz.external_user_id
       AND stg.internal_user_id = brz.internal_user_id
       AND stg.transaction_timestamp >= p_start_date
       AND stg.transaction_timestamp <  p_end_date);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_TRANSACTION_PRIZES');

  INSERT INTO SCHEMA_ETL.STG_PROGRESSIVE_PRIZES (
    session_id, external_user_id, internal_user_id,
    progressive_payout_amount, progressive_payout_type,
    progressive_payout_id, progressive_cashier_id,
    max_progressive_amount, progressive_prize_id)
  SELECT brz.session_id, brz.external_user_id, brz.internal_user_id,
    brz.progressive_payout_amount, brz.progressive_payout_type,
    brz.progressive_payout_id, brz.progressive_cashier_id,
    brz.max_progressive_amount, brz.progressive_prize_id
  FROM BRONZE.PROGRESSIVE_PRIZES_BRONZE brz
  WHERE EXISTS (
    SELECT 1 FROM SCHEMA_ETL.STG_TRANSACTIONS stg
     WHERE stg.session_id = brz.session_id
       AND stg.external_user_id = brz.external_user_id
       AND stg.internal_user_id = brz.internal_user_id
       AND stg.transaction_timestamp >= p_start_date
       AND stg.transaction_timestamp <  p_end_date);
  LOG_PKG.log_info(c_module_name, $$PLSQL_UNIT, $$PLSQL_LINE,
    SQL%ROWCOUNT || ' rows inserted into STG_PROGRESSIVE_PRIZES');
  COMMIT;
END Stage_Transaction_Data_From_Bronze;

END PKG_API_DATA_LOADER;
/
