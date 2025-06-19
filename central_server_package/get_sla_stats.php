<?php
// get_sla_stats.php (Central Server Version)
// ini_set('display_errors', 1); error_reporting(E_ALL); // For debugging

$db_file = '/opt/sla_monitor/central_sla_data.sqlite'; // Path to central database inside container
$config_file_path_central = '/opt/sla_monitor/sla_config.env'; // Central server's general config inside container

function parse_env_file($filepath) {
    $env_vars = [];
    if (!file_exists($filepath) || !is_readable($filepath)) {
        error_log("SLA Stats PHP Error: Config file {$filepath} not found or not readable.");
        return $env_vars;
    }
    $lines = file($filepath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        $line = trim($line);
        if (empty($line) || strpos($line, '#') === 0) { continue; }
        if (strpos($line, '=') !== false) {
            list($name, $value) = explode('=', $line, 2);
            $name = trim($name); $value = trim($value);
            if (preg_match('/^(\'(.*)\'|"(.*)")$/', $value, $matches)) { $value = isset($matches[3]) ? $matches[3] : $matches[2]; }
            $env_vars[$name] = $value;
        }
    }
    return $env_vars;
}

$config_values = parse_env_file($config_file_path_central);
$response_data['dashboard_refresh_interval_ms'] = isset($config_values['DASHBOARD_REFRESH_INTERVAL_MS']) ? (int)$config_values['DASHBOARD_REFRESH_INTERVAL_MS'] : 60000;

$current_isp_profile_id_req = isset($_GET['isp_id']) && !empty($_GET['isp_id']) ? (int)$_GET['isp_id'] : null;

header('Content-Type: application/json');
header('Cache-Control: no-cache, must-revalidate, no-store, max-age=0');
header('Pragma: no-cache'); header('Expires: 0');

$response_data['isp_profiles'] = [];
$response_data['current_isp_profile_id'] = null;
$response_data['current_isp_name'] = 'N/A';
$response_data['target_sla_percentage'] = 99.5; 
$response_data['periods'] = [];
$response_data['rtt_chart_data'] = [];
$response_data['speed_chart_data'] = [];
$response_data['average_slas'] = ['all' => null, 'isp' => null, 'client' => null];

try {
    if (!file_exists($db_file)) { throw new Exception("Central database file '{$db_file}' not found."); }
    if (!is_readable($db_file)) { $effectiveUser = function_exists('posix_getpwuid') && function_exists('posix_geteuid') ? posix_getpwuid(posix_geteuid())['name'] : get_current_user(); throw new Exception("Central database file '{$db_file}' not readable by web server (user: " . $effectiveUser . ")."); }
    
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    if (!$db) { throw new Exception("Could not connect to central database: " . SQLite3::lastErrorMsg()); }
    $db->exec("PRAGMA journal_mode=WAL;"); // Ensure WAL is used for read connections too for consistency with writer

    $profiles_query = "SELECT id, agent_name, agent_identifier, agent_type, sla_target_percentage FROM isp_profiles ORDER BY agent_type, agent_name";
    $profiles_result = $db->query($profiles_query);
    if (!$profiles_result) { throw new Exception("Failed to fetch ISP profiles: " . $db->lastErrorMsg()); }
    $first_profile_id_fallback = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = ['id' => (int)$profile['id'], 'name' => $profile['agent_name'] . " (" . $profile['agent_identifier'] . " - " . $profile['agent_type'] . ")"];
        if ($first_profile_id_fallback === null) $first_profile_id_fallback = (int)$profile['id'];
    }

    if ($current_isp_profile_id_req !== null) { $response_data['current_isp_profile_id'] = $current_isp_profile_id_req; }
    elseif ($first_profile_id_fallback !== null) { $response_data['current_isp_profile_id'] = $first_profile_id_fallback; }
    
    if ($response_data['current_isp_profile_id'] !== null) {
        $stmt_curr_prof = $db->prepare("SELECT agent_name, sla_target_percentage FROM isp_profiles WHERE id = :id");
        $stmt_curr_prof->bindValue(':id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER);
        $curr_prof_res = $stmt_curr_prof->execute();
        if ($prof_details = $curr_prof_res->fetchArray(SQLITE3_ASSOC)) {
            $response_data['current_isp_name'] = $prof_details['agent_name'];
            $response_data['target_sla_percentage'] = (float)$prof_details['sla_target_percentage'];
        }
        $stmt_curr_prof->close();

        $period_1_days_conf = isset($config_values['SLA_PERIOD_1_DAYS']) ? (int)$config_values['SLA_PERIOD_1_DAYS'] : 1;
        $period_7_days_conf = isset($config_values['SLA_PERIOD_7_DAYS']) ? (int)$config_values['SLA_PERIOD_7_DAYS'] : 7;
        $period_custom_days_conf = isset($config_values['SLA_PERIOD_CUSTOM_DAYS']) ? (int)$config_values['SLA_PERIOD_CUSTOM_DAYS'] : (isset($config_values['SLA_CALCULATION_PERIOD_DAYS']) ? (int)$config_values['SLA_CALCULATION_PERIOD_DAYS'] : 30);
        $php_periods = [];
        if ($period_1_days_conf > 0) $php_periods['last_1_day'] = ['label' => "Last {$period_1_days_conf} " . ($period_1_days_conf > 1 ? "Days" : "Day"), 'days' => $period_1_days_conf];
        if ($period_7_days_conf > 0 && $period_7_days_conf != $period_1_days_conf) $php_periods['last_7_days'] = ['label' => "Last {$period_7_days_conf} Days",   'days' => $period_7_days_conf];
        if ($period_custom_days_conf > 0 && $period_custom_days_conf != $period_1_days_conf && (!isset($php_periods['last_7_days']) || $period_custom_days_conf != $period_7_days_conf) ) { $php_periods['last_N_days'] = ['label' => "Last {$period_custom_days_conf} Days",  'days' => $period_custom_days_conf]; }
        elseif (empty($php_periods) && $period_custom_days_conf > 0) { $php_periods['last_N_days'] = ['label' => "Last {$period_custom_days_conf} Days",  'days' => $period_custom_days_conf];}

        foreach ($php_periods as $key => $period_config) {
            if ($period_config['days'] <=0) continue;
            $days_ago = (int)$period_config['days']; $start_date_obj = new DateTime("now", new DateTimeZone("UTC")); $start_date_obj->modify("-{$days_ago} days"); $start_date_iso = $start_date_obj->format("Y-m-d\TH:i:s\Z");
            $query = "SELECT COUNT(*) as total_intervals, COALESCE(SUM(sla_met_interval), 0) as met_intervals FROM sla_metrics WHERE isp_profile_id = :isp_id AND timestamp >= :start_date";
            $stmt = $db->prepare($query); if (!$stmt) { throw new Exception("Failed to prepare statement for {$period_config['label']}: " . $db->lastErrorMsg()); }
            $stmt->bindValue(':isp_id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER); $stmt->bindValue(':start_date', $start_date_iso, SQLITE3_TEXT);
            $result = $stmt->execute(); if (!$result) { throw new Exception("Failed to execute statement for {$period_config['label']}: " . $db->lastErrorMsg()); }
            $row = $result->fetchArray(SQLITE3_ASSOC); $stmt->close();
            $total_intervals = $row['total_intervals'] ?? 0; $met_intervals = $row['met_intervals'] ?? 0; $achieved_percentage = 0.0;
            if ($total_intervals > 0) { $achieved_percentage = round(($met_intervals / $total_intervals) * 100, 2); }
            $response_data['periods'][$key] = ['label' => $period_config['label'], 'total_intervals' => (int)$total_intervals, 'met_intervals' => (int)$met_intervals, 'achieved_percentage' => (float)$achieved_percentage, 'is_target_met' => ($total_intervals > 0 && $achieved_percentage >= $response_data['target_sla_percentage'])];
        }
        
        $chart_data_points_limit = 24;
        $rtt_chart_query = "SELECT timestamp, avg_rtt_ms, avg_loss_percent, avg_jitter_ms FROM sla_metrics WHERE isp_profile_id = :isp_id ORDER BY timestamp DESC LIMIT :limit";
        $rtt_chart_stmt = $db->prepare($rtt_chart_query); if (!$rtt_chart_stmt) { throw new Exception("Failed to prepare RTT chart: " . $db->lastErrorMsg()); } $rtt_chart_stmt->bindValue(':isp_id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER); $rtt_chart_stmt->bindValue(':limit', $chart_data_points_limit, SQLITE3_INTEGER); $rtt_chart_result = $rtt_chart_stmt->execute(); if (!$rtt_chart_result) { throw new Exception("Failed to execute RTT chart: " . $db->lastErrorMsg()); } $recent_rtt_metrics = []; while ($row = $rtt_chart_result->fetchArray(SQLITE3_ASSOC)) { $recent_rtt_metrics[] = $row; } $rtt_chart_stmt->close(); $response_data['rtt_chart_data'] = array_reverse($recent_rtt_metrics);
        
        $speed_chart_query = "SELECT timestamp, speedtest_download_mbps, speedtest_upload_mbps, speedtest_ping_ms, speedtest_jitter_ms FROM sla_metrics WHERE isp_profile_id = :isp_id AND speedtest_status = 'COMPLETED' ORDER BY timestamp DESC LIMIT :limit";
        $speed_chart_stmt = $db->prepare($speed_chart_query); if (!$speed_chart_stmt) { throw new Exception("Failed to prepare Speed chart: " . $db->lastErrorMsg()); } $speed_chart_stmt->bindValue(':isp_id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER); $speed_chart_stmt->bindValue(':limit', $chart_data_points_limit, SQLITE3_INTEGER); $speed_chart_result = $speed_chart_stmt->execute(); if (!$speed_chart_result) { throw new Exception("Failed to execute Speed chart: " . $db->lastErrorMsg()); } $recent_speed_metrics = []; while ($row = $speed_chart_result->fetchArray(SQLITE3_ASSOC)) { $recent_speed_metrics[] = $row; } $speed_chart_stmt->close(); $response_data['speed_chart_data'] = array_reverse($recent_speed_metrics);
    }

    // Calculate overall average SLAs for the last X days (defined by general config)
    $avg_sla_days = isset($config_values['SLA_CALCULATION_PERIOD_DAYS']) ? (int)$config_values['SLA_CALCULATION_PERIOD_DAYS'] : 30;
    if ($avg_sla_days > 0) {
        $start_date_avg_obj = new DateTime("now", new DateTimeZone("UTC")); $start_date_avg_obj->modify("-{$avg_sla_days} days"); $start_date_avg_iso = $start_date_avg_obj->format("Y-m-d\TH:i:s\Z");
        
        $avg_queries = [
            'all'    => "SELECT COUNT(*) as total, COALESCE(SUM(sla_met_interval), 0) as met FROM sla_metrics WHERE timestamp >= :start_date",
            'isp'    => "SELECT COUNT(*) as total, COALESCE(SUM(sm.sla_met_interval), 0) as met FROM sla_metrics sm JOIN isp_profiles ip ON sm.isp_profile_id = ip.id WHERE ip.agent_type = 'ISP' AND sm.timestamp >= :start_date",
            'client' => "SELECT COUNT(*) as total, COALESCE(SUM(sm.sla_met_interval), 0) as met FROM sla_metrics sm JOIN isp_profiles ip ON sm.isp_profile_id = ip.id WHERE ip.agent_type = 'Client' AND sm.timestamp >= :start_date",
        ];
        foreach ($avg_queries as $type => $sql) {
            $stmt_avg = $db->prepare($sql); $stmt_avg->bindValue(':start_date', $start_date_avg_iso, SQLITE3_TEXT); $res_avg = $stmt_avg->execute(); $row_avg = $res_avg->fetchArray(SQLITE3_ASSOC); $stmt_avg->close();
            if ($row_avg && isset($row_avg['total']) && $row_avg['total'] > 0) { $response_data['average_slas'][$type] = round(((int)$row_avg['met'] / (int)$row_avg['total']) * 100, 2); }
        }
    }

    $db->close();
} catch (Exception $e) { error_log("SLA Stats PHP Error: " . $e->getMessage()); http_response_code(500); $response_data = ['error' => 'Could not retrieve SLA statistics. ' . $e->getMessage()];}
echo json_encode($response_data);
?>