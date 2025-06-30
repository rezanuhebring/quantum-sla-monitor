<?php
// get_sla_stats.php - FINAL PRODUCTION VERSION
// Enhanced to provide a high-level summary view for all agents.

ini_set('display_errors', 0);
ini_set('log_errors', 1);

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';
$config_file_path_central = '/opt/sla_monitor/sla_config.env';

// --- Helper Functions ---
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
    'current_isp_profile_id' => null,
    'current_isp_name' => 'N/A',
    'target_sla_percentage' => 99.5,
    'periods' => [],
    'rtt_chart_data' => [],
    'speed_chart_data' => [],
    'latest_check' => null,
    'average_slas' => ['all' => null, 'isp' => null, 'client' => null], // For summary view
    'dashboard_refresh_interval_ms' => 60000
];

try {
    $config_values = parse_env_file($config_file_path_central);
    $response_data['dashboard_refresh_interval_ms'] = (int)($config_values['DASHBOARD_REFRESH_INTERVAL_MS'] ?? 60000);
    $response_data['target_sla_percentage'] = (float)($config_values['SLA_TARGET_PERCENTAGE'] ?? 99.5);

    if (!file_exists($db_file)) { throw new Exception("Central database file not found."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);

    // --- Get all active ISP profiles for the dropdown menu ---
    $profiles_result = $db->query("SELECT id, agent_name, agent_identifier, agent_type, is_active, last_heard_from, last_reported_hostname, last_reported_source_ip FROM isp_profiles WHERE is_active = 1 ORDER BY agent_type, agent_name");
    $first_active_profile_id = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = $profile;
        if ($first_active_profile_id === null) $first_active_profile_id = (int)$profile['id'];
    }

    $current_isp_profile_id_req = filter_input(INPUT_GET, 'isp_id', FILTER_VALIDATE_INT);

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

        // Fetch latest check, charts, and individual SLA periods
        $latest_check_stmt = $db->prepare("SELECT * FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp DESC LIMIT 1");
        $latest_check_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER);
        if ($latest_check_result = $latest_check_stmt->execute()->fetchArray(SQLITE3_ASSOC)) { $response_data['latest_check'] = $latest_check_result; }
        $latest_check_stmt->close();
        
        $chart_limit = 48;
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

    }

    // --- CALCULATIONS FOR BOTH VIEWS ---
    $period_defs = [
        'last_1_day' => ['days' => (int)($config_values['SLA_PERIOD_1_DAYS'] ?? 1), 'label' => 'Last 24 Hours'],
        'last_7_days' => ['days' => (int)($config_values['SLA_PERIOD_7_DAYS'] ?? 7), 'label' => 'Last 7 Days'],
        'last_30_days' => ['days' => (int)($config_values['SLA_PERIOD_CUSTOM_DAYS'] ?? 30), 'label' => 'Last 30 Days']
    ];
    $base_query = "SELECT COUNT(*) as total_intervals, SUM(sla_met_interval) as met_intervals FROM sla_metrics WHERE timestamp >= :start_date";

    // For individual view
    if ($response_data['current_isp_profile_id']) {
        foreach ($period_defs as $key => $def) {
            $start_date = (new DateTime("-{$def['days']} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z");
            $stmt = $db->prepare($base_query . " AND isp_profile_id = :id");
            $stmt->bindValue(':start_date', $start_date); $stmt->bindValue(':id', $response_data['current_isp_profile_id']);
            $row = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
            $total = (int)($row['total_intervals'] ?? 0); $met = (int)($row['met_intervals'] ?? 0);
            $achieved = ($total > 0) ? round(($met / $total) * 100, 2) : 0.0;
            $response_data['periods'][$key] = ['label' => $def['label'], 'total_intervals' => $total, 'met_intervals' => $met, 'achieved_percentage' => $achieved, 'is_target_met' => ($achieved >= $response_data['target_sla_percentage'])];
        }
    } else { // For summary view
        foreach ($period_defs as $key => $def) {
            $start_date = (new DateTime("-{$def['days']} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z");
            $stmt_all = $db->prepare($base_query); $stmt_all->bindValue(':start_date', $start_date);
            $row_all = $stmt_all->execute()->fetchArray(SQLITE3_ASSOC);
            $total_all = (int)($row_all['total_intervals'] ?? 0); $met_all = (int)($row_all['met_intervals'] ?? 0);
            $achieved_all = ($total_all > 0) ? round(($met_all / $total_all) * 100, 2) : 0.0;
            $response_data['periods'][$key] = ['label' => $def['label'], 'achieved_percentage' => $achieved_all];
        }
        $summary_query = $db->prepare("SELECT ip.agent_type, COUNT(*) as total, SUM(sm.sla_met_interval) as met FROM sla_metrics sm JOIN isp_profiles ip ON sm.isp_profile_id = ip.id WHERE sm.timestamp >= :start_date GROUP BY ip.agent_type");
        $summary_query->bindValue(':start_date', (new DateTime("-{$period_defs['last_30_days']['days']} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        $summary_results = $summary_query->execute();
        while($row = $summary_results->fetchArray(SQLITE3_ASSOC)){
            $type_key = strtolower($row['agent_type']);
            if (isset($response_data['average_slas'][$type_key])){
                $total = (int)$row['total']; $met = (int)$row['met'];
                if($total > 0) { $response_data['average_slas'][$type_key] = round(($met / $total) * 100, 2); }
            }
        }
    }
    
    $db->close();
} catch (Exception $e) {
    http_response_code(500);
    $response_data = ['error' => 'A server error occurred while retrieving statistics.', 'message' => $e->getMessage()];
    error_log("SLA Stats PHP Error: " . $e->getMessage());
}

echo json_encode($response_data, JSON_NUMERIC_CHECK);
?>