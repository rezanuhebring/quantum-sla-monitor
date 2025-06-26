<?php
// get_sla_stats.php (Central Server Version) - FINAL, UNIFIED VERSION
ini_set('display_errors', 0); // Never display errors on a JSON endpoint
ini_set('log_errors', 1);

$db_file = '/opt/sla_monitor/central_sla_data.sqlite';
$config_file_path_central = '/opt/sla_monitor/sla_config.env';

// Helper function to parse .env file
function parse_env_file($filepath) {
    $env_vars = [];
    if (!file_exists($filepath) || !is_readable($filepath)) { return $env_vars; }
    $lines = file($filepath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (empty(trim($line)) || strpos(trim($line), '#') === 0) continue;
        if (strpos($line, '=') !== false) {
            list($name, $value) = explode('=', $line, 2);
            $env_vars[trim($name)] = trim($value, " '\"");
        }
    }
    return $env_vars;
}

// Set JSON headers
header('Content-Type: application/json');
header('Cache-Control: no-cache, must-revalidate, no-store, max-age=0');

// Initialize the final response structure
$response_data = [
    'isp_profiles' => [],
    'current_isp_profile_id' => null,
    'current_isp_name' => 'N/A',
    'target_sla_percentage' => 99.5,
    'periods' => [],
    'rtt_chart_data' => [],
    'speed_chart_data' => [],
    'latest_check' => null, // Will hold the most recent data point
    'dashboard_refresh_interval_ms' => 60000
];

try {
    // Load central configuration
    $config_values = parse_env_file($config_file_path_central);
    $response_data['dashboard_refresh_interval_ms'] = (int)($config_values['DASHBOARD_REFRESH_INTERVAL_MS'] ?? 60000);

    // Establish a READ-ONLY database connection
    if (!file_exists($db_file)) { throw new Exception("Central database file not found."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    if (!$db) { throw new Exception("Could not connect to central database."); }

    // --- Get all ISP profiles for the dropdown menu ---
    $profiles_result = $db->query("SELECT id, agent_name, agent_identifier, agent_type, is_active FROM isp_profiles ORDER BY agent_type, is_active DESC, agent_name");
    $first_active_profile_id = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = $profile;
        if ($first_active_profile_id === null && $profile['is_active'] == 1) {
            $first_active_profile_id = (int)$profile['id'];
        }
    }

    // Determine which profile is being viewed (from URL or fallback to first active)
    $current_isp_profile_id_req = filter_input(INPUT_GET, 'isp_id', FILTER_VALIDATE_INT);
    $response_data['current_isp_profile_id'] = $current_isp_profile_id_req ?: $first_active_profile_id;

    // If there's a valid profile to show data for, fetch all its details
    if ($response_data['current_isp_profile_id'] !== null) {
        $current_id = $response_data['current_isp_profile_id'];

        // Get the selected profile's name and SLA target
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
        $latest_check_result = $latest_check_stmt->execute()->fetchArray(SQLITE3_ASSOC);
        if ($latest_check_result) {
            $response_data['latest_check'] = $latest_check_result;
        }
        $latest_check_stmt->close();

        // Fetch historical data for charts
        $chart_limit = 48; // Show more data points for a better view
        
        $rtt_chart_stmt = $db->prepare("SELECT timestamp, avg_rtt_ms, avg_loss_percent, avg_jitter_ms FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp DESC LIMIT :limit");
        $rtt_chart_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER);
        $rtt_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $rtt_rows = [];
        $rtt_result = $rtt_chart_stmt->execute();
        while($row = $rtt_result->fetchArray(SQLITE3_ASSOC)) { $rtt_rows[] = $row; }
        $response_data['rtt_chart_data'] = array_reverse($rtt_rows);
        $rtt_chart_stmt->close();

        $speed_chart_stmt = $db->prepare("SELECT timestamp, speedtest_download_mbps, speedtest_upload_mbps FROM sla_metrics WHERE isp_profile_id = :id AND speedtest_status = 'COMPLETED' ORDER BY timestamp DESC LIMIT :limit");
        $speed_chart_stmt->bindValue(':id', $current_id, SQLITE3_INTEGER);
        $speed_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $speed_rows = [];
        $speed_result = $speed_chart_stmt->execute();
        while($row = $speed_result->fetchArray(SQLITE3_ASSOC)) { $speed_rows[] = $row; }
        $response_data['speed_chart_data'] = array_reverse($speed_rows);
        $speed_chart_stmt->close();
        
        // Use a single, optimized query for all historical SLA periods
        $period_1_days = (int)($config_values['SLA_PERIOD_1_DAYS'] ?? 1);
        $period_7_days = (int)($config_values['SLA_PERIOD_7_DAYS'] ?? 7);
        $period_30_days = (int)($config_values['SLA_PERIOD_CUSTOM_DAYS'] ?? 30);

        $date_30_days_ago_iso = (new DateTime("-{$period_30_days} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z");

        $sla_query = $db->prepare("
            SELECT
                CASE
                    WHEN timestamp >= :date_1_day THEN 'period_1'
                    WHEN timestamp >= :date_7_days THEN 'period_7'
                    ELSE 'period_30'
                END as period,
                COUNT(*) as total_intervals,
                SUM(sla_met_interval) as met_intervals
            FROM sla_metrics
            WHERE isp_profile_id = :isp_id AND timestamp >= :date_30_days
            GROUP BY period
        ");
        $sla_query->bindValue(':isp_id', $current_id, SQLITE3_INTEGER);
        $sla_query->bindValue(':date_1_day', (new DateTime("-{$period_1_days} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        $sla_query->bindValue(':date_7_days', (new DateTime("-{$period_7_days} days", new DateTimeZone("UTC")))->format("Y-m-d\TH:i:s\Z"));
        $sla_query->bindValue(':date_30_days', $date_30_days_ago_iso);
        
        $sla_results = $sla_query->execute();
        $stats = ['period_1' => ['total' => 0, 'met' => 0], 'period_7' => ['total' => 0, 'met' => 0], 'period_30' => ['total' => 0, 'met' => 0]];
        while ($row = $sla_results->fetchArray(SQLITE3_ASSOC)) {
            if ($row['period']) {
                $stats[$row['period']]['total'] = (int)$row['total_intervals'];
                $stats[$row['period']]['met'] = (int)$row['met_intervals'];
            }
        }
        $sla_query->close();
        
        // Accumulate totals since the query groups them exclusively
        $stats['period_7']['total'] += $stats['period_1']['total']; $stats['period_7']['met'] += $stats['period_1']['met'];
        $stats['period_30']['total'] += $stats['period_7']['total']; $stats['period_30']['met'] += $stats['period_7']['met'];

        $period_defs = [
            "last_{$period_1_days}_day" => ['label' => "Last {$period_1_days} Day(s)", 'data' => $stats['period_1']],
            "last_{$period_7_days}_days" => ['label' => "Last {$period_7_days} Days", 'data' => $stats['period_7']],
            "last_{$period_30_days}_days" => ['label' => "Last {$period_30_days} Days", 'data' => $stats['period_30']]
        ];

        foreach ($period_defs as $key => $def) {
            $total = $def['data']['total'];
            $met = $def['data']['met'];
            $achieved = ($total > 0) ? round(($met / $total) * 100, 2) : 0.0;
            $response_data['periods'][$key] = [
                'label' => $def['label'],
                'total_intervals' => $total,
                'met_intervals' => $met,
                'achieved_percentage' => $achieved,
                'is_target_met' => ($achieved >= $response_data['target_sla_percentage'])
            ];
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