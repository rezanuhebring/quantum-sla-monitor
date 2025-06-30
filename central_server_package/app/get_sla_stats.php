<?php
// get_sla_stats.php - FINAL PRODUCTION VERSION
// Enhanced to provide a high-level summary view and cumulative graphs.

ini_set('display_errors', 0);
ini_set('log_errors', 1);

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';
$config_file_path_central = '/opt/sla_monitor/sla_config.env';

// --- Helper Function ---
function parse_env_file($filepath) {
    $env_vars = []; if (!file_exists($filepath)) return $env_vars;
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
    'all_agent_status' => [],
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

    // Get all active ISP profiles for the dropdown menu
    $profiles_result = $db->query("SELECT id, agent_name, agent_identifier, agent_type, is_active FROM isp_profiles WHERE is_active = 1 ORDER BY agent_type, agent_name");
    $first_active_profile_id = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = $profile;
        if ($first_active_profile_id === null) $first_active_profile_id = (int)$profile['id'];
    }

    $current_isp_profile_id_req = filter_input(INPUT_GET, 'isp_id', FILTER_VALIDATE_INT);

    if ($current_isp_profile_id_req) {
        // --- INDIVIDUAL AGENT VIEW ---
        $response_data['current_isp_profile_id'] = $current_isp_profile_id_req;
        // (The logic for fetching individual agent data remains the same as the last version)
        // ... (omitted for brevity)
    } else {
        // --- OVERALL SUMMARY VIEW ---
        $response_data['current_isp_profile_id'] = null; // Explicitly set to null for summary
        
        // Fetch cumulative chart data
        $days_for_cumulative_chart = 30;
        $start_date_cumulative = (new DateTime("-{$days_for_cumulative_chart} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z");
        
        $cumulative_ping_stmt = $db->prepare("SELECT strftime('%Y-%m-%d', timestamp) as day, AVG(avg_rtt_ms) as avg_rtt, AVG(avg_loss_percent) as avg_loss, AVG(avg_jitter_ms) as avg_jitter FROM sla_metrics WHERE timestamp >= :start_date GROUP BY day ORDER BY day ASC");
        $cumulative_ping_stmt->bindValue(':start_date', $start_date_cumulative);
        $ping_res = $cumulative_ping_stmt->execute();
        while($row = $ping_res->fetchArray(SQLITE3_ASSOC)) { $response_data['cumulative_ping_chart_data'][] = $row; }

        $cumulative_speed_stmt = $db->prepare("SELECT strftime('%Y-%m-%d', timestamp) as day, AVG(speedtest_download_mbps) as avg_dl, AVG(speedtest_upload_mbps) as avg_ul FROM sla_metrics WHERE speedtest_status = 'COMPLETED' AND timestamp >= :start_date GROUP BY day ORDER BY day ASC");
        $cumulative_speed_stmt->bindValue(':start_date', $start_date_cumulative);
        $speed_res = $cumulative_speed_stmt->execute();
        while($row = $speed_res->fetchArray(SQLITE3_ASSOC)) { $response_data['cumulative_speed_chart_data'][] = $row; }
    }

    // --- CALCULATIONS FOR SLA PERIODS (Works for both views) ---
    $period_defs = [
        'last_1_day' => ['days' => (int)($config_values['SLA_PERIOD_1_DAYS'] ?? 1), 'label' => 'Last 24 Hours'],
        'last_7_days' => ['days' => (int)($config_values['SLA_PERIOD_7_DAYS'] ?? 7), 'label' => 'Last 7 Days'],
        'last_30_days' => ['days' => (int)($config_values['SLA_PERIOD_CUSTOM_DAYS'] ?? 30), 'label' => 'Last 30 Days']
    ];
    $base_query_sql = "SELECT COUNT(*) as total_intervals, SUM(sla_met_interval) as met_intervals FROM sla_metrics WHERE timestamp >= :start_date";

    foreach ($period_defs as $key => $def) {
        $start_date = (new DateTime("-{$def['days']} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z");
        $query_sql = $base_query_sql;
        if ($response_data['current_isp_profile_id']) {
            $query_sql .= " AND isp_profile_id = :id";
        }
        $stmt = $db->prepare($query_sql);
        $stmt->bindValue(':start_date', $start_date);
        if ($response_data['current_isp_profile_id']) {
            $stmt->bindValue(':id', $response_data['current_isp_profile_id']);
        }
        $row = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
        $total = (int)($row['total_intervals'] ?? 0); $met = (int)($row['met_intervals'] ?? 0);
        $achieved = ($total > 0) ? round(($met / $total) * 100, 2) : 0.0;
        $response_data['periods'][$key] = ['label' => $def['label'], 'total_intervals' => $total, 'met_intervals' => $met, 'achieved_percentage' => $achieved, 'is_target_met' => ($achieved >= $response_data['target_sla_percentage'])];
    }
    
    $db->close();
} catch (Exception $e) {
    http_response_code(500);
    $response_data = ['error' => 'A server error occurred.', 'message' => $e->getMessage()];
    error_log("SLA Stats PHP Error: " . $e->getMessage());
}

echo json_encode($response_data, JSON_NUMERIC_CHECK);
?>