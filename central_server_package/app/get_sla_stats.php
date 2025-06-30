<?php
// get_sla_stats.php - FINAL PRODUCTION VERSION
// Enhanced to provide a summary of all agent statuses and detailed data in one call.

ini_set('display_errors', 0); // Never display errors on a JSON endpoint
ini_set('log_errors', 1);

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';
$config_file_path_central = '/opt/sla_monitor/sla_config.env';

// --- Helper Function ---
function parse_env_file($filepath) {
    $env_vars = []; if (!file_exists($filepath) || !is_readable($filepath)) return $env_vars;
    $lines = file($filepath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (empty(trim($line)) || strpos(trim($line), '#') === 0) continue;
        if (strpos($line, '=') !== false) { list($name, $value) = explode('=', $line, 2); $env_vars[trim($name)] = trim($value, " '\""); }
    }
    return $env_vars;
}

// --- Main Logic ---
header('Content-Type: application/json');
header('Cache-Control: no-cache, must-revalidate, no-store, max-age=0');

$response_data = [
    'isp_profiles' => [],
    'all_agent_status' => [], // For the main summary view
    'current_isp_profile_id' => null,
    'current_isp_name' => 'N/A',
    'target_sla_percentage' => 99.5,
    'periods' => [],
    'rtt_chart_data' => [],
    'speed_chart_data' => [],
    'cumulative_ping_chart_data' => [], // For new summary graph
    'cumulative_speed_chart_data' => [], // For new summary graph
    'latest_check' => null,
    'dashboard_refresh_interval_ms' => 60000
];

try {
    $config_values = parse_env_file($config_file_path_central);
    $response_data['dashboard_refresh_interval_ms'] = (int)($config_values['DASHBOARD_REFRESH_INTERVAL_MS'] ?? 60000);
    $response_data['target_sla_percentage'] = (float)($config_values['SLA_TARGET_PERCENTAGE'] ?? 99.5);

    if (!file_exists($db_file)) { throw new Exception("Central database file not found."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);

    // Get all ISP profiles for the dropdown menu
    $profiles_result = $db->query("SELECT id, agent_name, agent_identifier, agent_type, is_active FROM isp_profiles ORDER BY agent_type, is_active DESC, agent_name");
    $first_active_profile_id = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = $profile;
        if ($first_active_profile_id === null && $profile['is_active'] == 1) { $first_active_profile_id = (int)$profile['id']; }
    }

    $current_isp_profile_id_req = filter_input(INPUT_GET, 'isp_id', FILTER_VALIDATE_INT);
    
    // --- Period Definitions ---
    $period_defs = [
        'last_1_day' => ['days' => 1, 'label' => 'Last 24 Hours'],
        'last_7_days' => ['days' => 7, 'label' => 'Last 7 Days'],
        'last_30_days' => ['days' => 30, 'label' => 'Last 30 Days']
    ];
    
    if ($current_isp_profile_id_req) {
        // --- INDIVIDUAL AGENT VIEW ---
        $response_data['current_isp_profile_id'] = $current_isp_profile_id_req;
        $current_id = $response_data['current_isp_profile_id'];

        $stmt_curr_prof = $db->prepare("SELECT agent_name, sla_target_percentage FROM isp_profiles WHERE id = :id");
        $stmt_curr_prof->bindValue(':id', $current_id, SQLITE3_INTEGER);
        if ($prof_details = $stmt_curr_prof->execute()->fetchArray(SQLITE3_ASSOC)) {
            $response_data['current_isp_name'] = $prof_details['agent_name'];
            $response_data['target_sla_percentage'] = (float)$prof_details['sla_target_percentage'];
        }
        $stmt_curr_prof->close();

        // Fetch the single latest metric entry for the "live" cards
        $latest_check_stmt = $db->prepare("SELECT * FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp DESC LIMIT 1");
        $latest_check_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER);
        if ($latest_check_result = $latest_check_stmt->execute()->fetchArray(SQLITE3_ASSOC)) { $response_data['latest_check'] = $latest_check_result; }
        $latest_check_stmt->close();
        
        // Fetch historical data for charts
        $chart_limit = 96;
        $rtt_chart_stmt = $db->prepare("SELECT timestamp, avg_rtt_ms, avg_loss_percent, avg_jitter_ms FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp DESC LIMIT :limit");
        $rtt_chart_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER); $rtt_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $rtt_rows = []; $rtt_result = $rtt_chart_stmt->execute(); while($row = $rtt_result->fetchArray(SQLITE3_ASSOC)) { $rtt_rows[] = $row; }
        $response_data['rtt_chart_data'] = array_reverse($rtt_rows);
        $rtt_chart_stmt->close();

        $speed_chart_stmt = $db->prepare("SELECT timestamp, speedtest_download_mbps, speedtest_upload_mbps FROM sla_metrics WHERE isp_profile_id = :id AND speedtest_status = 'COMPLETED' ORDER BY timestamp DESC LIMIT :limit");
        $speed_chart_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER); $speed_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $speed_rows = []; $speed_result = $speed_chart_stmt->execute(); while($row = $speed_result->fetchArray(SQLITE3_ASSOC)) { $speed_rows[] = $row; }
        $response_data['speed_chart_data'] = array_reverse($speed_rows);
        $speed_chart_stmt->close();
    } else {
        // --- OVERALL SUMMARY VIEW ---
        // Get latest status for all agents
        $all_status_query = $db->query("SELECT sm.* FROM sla_metrics sm INNER JOIN (SELECT isp_profile_id, MAX(id) as max_id FROM sla_metrics GROUP BY isp_profile_id) as latest ON sm.isp_profile_id = latest.isp_profile_id AND sm.id = latest.max_id INNER JOIN isp_profiles ip ON sm.isp_profile_id = ip.id WHERE ip.is_active = 1");
        while ($status = $all_status_query->fetchArray(SQLITE3_ASSOC)) { $response_data['all_agent_status'][$status['isp_profile_id']] = $status; }
        
        // Fetch cumulative chart data
        $cumulative_ping_stmt = $db->prepare("SELECT strftime('%Y-%m-%d', timestamp) as day, AVG(avg_rtt_ms) as avg_rtt, AVG(avg_loss_percent) as avg_loss, AVG(avg_jitter_ms) as avg_jitter FROM sla_metrics WHERE timestamp >= :start_date GROUP BY day ORDER BY day ASC");
        $cumulative_ping_stmt->bindValue(':start_date', (new DateTime("-30 days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        $ping_res = $cumulative_ping_stmt->execute(); while($row = $ping_res->fetchArray(SQLITE3_ASSOC)) { $response_data['cumulative_ping_chart_data'][] = $row; }

        $cumulative_speed_stmt = $db->prepare("SELECT strftime('%Y-%m-%d', timestamp) as day, AVG(speedtest_download_mbps) as avg_dl, AVG(speedtest_upload_mbps) as avg_ul FROM sla_metrics WHERE speedtest_status = 'COMPLETED' AND timestamp >= :start_date GROUP BY day ORDER BY day ASC");
        $cumulative_speed_stmt->bindValue(':start_date', (new DateTime("-30 days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        $speed_res = $cumulative_speed_stmt->execute(); while($row = $speed_res->fetchArray(SQLITE3_ASSOC)) { $response_data['cumulative_speed_chart_data'][] = $row; }
    }
    
    // CALCULATE SLA PERIODS (For both views)
    $query_base = "SELECT COUNT(*) as total_intervals, SUM(sla_met_interval) as met_intervals FROM sla_metrics WHERE timestamp >= :start_date";
    if ($current_isp_profile_id_req) { $query_base .= " AND isp_profile_id = :id"; }

    foreach($period_defs as $key => $def) {
        $stmt = $db->prepare($query_base);
        $stmt->bindValue(':start_date', (new DateTime("-{$def['days']} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        if ($current_isp_profile_id_req) { $stmt->bindValue(':id', $current_isp_profile_id_req); }
        $row = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
        $total = (int)($row['total_intervals'] ?? 0); $met = (int)($row['met_intervals'] ?? 0);
        $achieved = ($total > 0) ? round(($met / $total) * 100, 2) : 0.0;
        $response_data['periods'][$key] = [ 'label' => $def['label'], 'total_intervals' => $total, 'met_intervals' => $met, 'achieved_percentage' => $achieved, 'is_target_met' => ($achieved >= $response_data['target_sla_percentage'])];
    }
    
    $db->close();
} catch (Exception $e) {
    http_response_code(500);
    $response_data = ['error' => 'A server error occurred.', 'message' => $e->getMessage()];
    error_log("SLA Stats PHP Error: " . $e->getMessage());
}

echo json_encode($response_data, JSON_NUMERIC_CHECK);
?>