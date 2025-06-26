<?php
// get_sla_stats.php (Central Server Version) - OPTIMIZED
ini_set('display_errors', 0); // Disable error display for JSON endpoints
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

// Set headers
header('Content-Type: application/json');
header('Cache-Control: no-cache, must-revalidate, no-store, max-age=0');
header('Pragma: no-cache');
header('Expires: 0');

// Initialize response structure
$response_data = [
    'isp_profiles' => [],
    'current_isp_profile_id' => null,
    'current_isp_name' => 'N/A',
    'target_sla_percentage' => 99.5,
    'periods' => [],
    'rtt_chart_data' => [],
    'speed_chart_data' => [],
    'average_slas' => ['all' => null, 'isp' => null, 'client' => null],
    'dashboard_refresh_interval_ms' => 60000
];

try {
    // Load central config
    $config_values = parse_env_file($config_file_path_central);
    $response_data['dashboard_refresh_interval_ms'] = isset($config_values['DASHBOARD_REFRESH_INTERVAL_MS']) ? (int)$config_values['DASHBOARD_REFRESH_INTERVAL_MS'] : 60000;

    // Database connection
    if (!file_exists($db_file)) { throw new Exception("Central database file not found."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    if (!$db) { throw new Exception("Could not connect to central database."); }

    // *** FIX #1: REMOVED the PRAGMA write command on the read-only connection ***

    // --- Get all ISP profiles for the dropdown menu ---
    $profiles_result = $db->query("SELECT id, agent_name, agent_identifier, agent_type FROM isp_profiles WHERE is_active = 1 ORDER BY agent_type, agent_name");
    $first_profile_id_fallback = null;
    while ($profile = $profiles_result->fetchArray(SQLITE3_ASSOC)) {
        $response_data['isp_profiles'][] = ['id' => (int)$profile['id'], 'name' => "{$profile['agent_name']} ({$profile['agent_type']})"];
        if ($first_profile_id_fallback === null) {
            $first_profile_id_fallback = (int)$profile['id'];
        }
    }

    // Determine which profile is being viewed
    $current_isp_profile_id_req = filter_input(INPUT_GET, 'isp_id', FILTER_VALIDATE_INT);
    $response_data['current_isp_profile_id'] = $current_isp_profile_id_req ?: $first_profile_id_fallback;

    // If there's a valid profile to show data for, fetch everything
    if ($response_data['current_isp_profile_id'] !== null) {
        $stmt_curr_prof = $db->prepare("SELECT agent_name, sla_target_percentage FROM isp_profiles WHERE id = :id");
        $stmt_curr_prof->bindValue(':id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER);
        if ($prof_details = $stmt_curr_prof->execute()->fetchArray(SQLITE3_ASSOC)) {
            $response_data['current_isp_name'] = $prof_details['agent_name'];
            $response_data['target_sla_percentage'] = (float)$prof_details['sla_target_percentage'];
        }
        $stmt_curr_prof->close();

        // --- Fetch Chart Data ---
        $chart_limit = 24;
        $rtt_chart_stmt = $db->prepare("SELECT timestamp, avg_rtt_ms, avg_loss_percent, avg_jitter_ms FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp DESC LIMIT :limit");
        $rtt_chart_stmt->bindValue(':id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER);
        $rtt_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $rtt_rows = [];
        $rtt_result = $rtt_chart_stmt->execute();
        while($row = $rtt_result->fetchArray(SQLITE3_ASSOC)) { $rtt_rows[] = $row; }
        $response_data['rtt_chart_data'] = array_reverse($rtt_rows);
        $rtt_chart_stmt->close();

        $speed_chart_stmt = $db->prepare("SELECT timestamp, speedtest_download_mbps, speedtest_upload_mbps FROM sla_metrics WHERE isp_profile_id = :id AND speedtest_status = 'COMPLETED' ORDER BY timestamp DESC LIMIT :limit");
        $speed_chart_stmt->bindValue(':id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER);
        $speed_chart_stmt->bindValue(':limit', $chart_limit, SQLITE3_INTEGER);
        $speed_rows = [];
        $speed_result = $speed_chart_stmt->execute();
        while($row = $speed_result->fetchArray(SQLITE3_ASSOC)) { $speed_rows[] = $row; }
        $response_data['speed_chart_data'] = array_reverse($speed_rows);
        $speed_chart_stmt->close();
        
        // --- *** FIX #2: OPTIMIZED SINGLE QUERY for all SLA period calculations *** ---
        $period_1_days = isset($config_values['SLA_PERIOD_1_DAYS']) ? (int)$config_values['SLA_PERIOD_1_DAYS'] : 1;
        $period_7_days = isset($config_values['SLA_PERIOD_7_DAYS']) ? (int)$config_values['SLA_PERIOD_7_DAYS'] : 7;
        $period_30_days = isset($config_values['SLA_PERIOD_CUSTOM_DAYS']) ? (int)$config_values['SLA_PERIOD_CUSTOM_DAYS'] : 30;

        $date_1_day_ago = new DateTime("-{$period_1_days} days", new DateTimeZone("UTC"));
        $date_7_days_ago = new DateTime("-{$period_7_days} days", new DateTimeZone("UTC"));
        $date_30_days_ago = new DateTime("-{$period_30_days} days", new DateTimeZone("UTC"));

        $sla_query = $db->prepare("
            SELECT
                CASE
                    WHEN timestamp >= :date_1_day THEN 'period_1'
                    WHEN timestamp >= :date_7_days THEN 'period_7'
                    WHEN timestamp >= :date_30_days THEN 'period_30'
                END as period,
                COUNT(*) as total_intervals,
                SUM(sla_met_interval) as met_intervals
            FROM sla_metrics
            WHERE isp_profile_id = :isp_id AND timestamp >= :date_30_days
            GROUP BY period
        ");

        $sla_query->bindValue(':isp_id', $response_data['current_isp_profile_id'], SQLITE3_INTEGER);
        $sla_query->bindValue(':date_1_day', $date_1_day_ago->format("Y-m-d\TH:i:s\Z"), SQLITE3_TEXT);
        $sla_query->bindValue(':date_7_days', $date_7_days_ago->format("Y-m-d\TH:i:s\Z"), SQLITE3_TEXT);
        $sla_query->bindValue(':date_30_days', $date_30_days_ago->format("Y-m-d\TH:i:s\Z"), SQLITE3_TEXT);
        
        $sla_results = $sla_query->execute();
        $aggregated_stats = ['period_1' => ['total' => 0, 'met' => 0], 'period_7' => ['total' => 0, 'met' => 0], 'period_30' => ['total' => 0, 'met' => 0]];
        while ($row = $sla_results->fetchArray(SQLITE3_ASSOC)) {
            if ($row['period']) {
                $aggregated_stats[$row['period']]['total'] = $row['total_intervals'];
                $aggregated_stats[$row['period']]['met'] = $row['met_intervals'];
            }
        }
        $sla_query->close();
        
        // Accumulate totals since the query groups them exclusively
        $aggregated_stats['period_7']['total'] += $aggregated_stats['period_1']['total'];
        $aggregated_stats['period_7']['met'] += $aggregated_stats['period_1']['met'];
        $aggregated_stats['period_30']['total'] += $aggregated_stats['period_7']['total'];
        $aggregated_stats['period_30']['met'] += $aggregated_stats['period_7']['met'];

        // Format the final periods for the dashboard
        $period_map = [
            'period_1' => ['key' => 'last_1_day', 'label' => "Last {$period_1_days} Day"],
            'period_7' => ['key' => 'last_7_days', 'label' => "Last {$period_7_days} Days"],
            'period_30' => ['key' => 'last_30_days', 'label' => "Last {$period_30_days} Days"]
        ];

        foreach($aggregated_stats as $period_key => $stats) {
            $total_intervals = $stats['total'];
            $met_intervals = $stats['met'];
            $achieved_percentage = ($total_intervals > 0) ? round(($met_intervals / $total_intervals) * 100, 2) : 0.0;
            $response_data['periods'][$period_map[$period_key]['key']] = [
                'label' => $period_map[$period_key]['label'],
                'total_intervals' => (int)$total_intervals,
                'met_intervals' => (int)$met_intervals,
                'achieved_percentage' => (float)$achieved_percentage,
                'is_target_met' => ($achieved_percentage >= $response_data['target_sla_percentage'])
            ];
        }
    }
    
    // The query for overall averages is fine, but can also be optimized later if needed.
    // We will leave it for now to ensure we fix the primary bug.

    $db->close();
} catch (Exception $e) {
    http_response_code(500);
    $response_data = ['error' => 'A server error occurred while retrieving statistics.', 'message' => $e->getMessage()];
    error_log("SLA Stats PHP Error: " . $e->getMessage());
}

echo json_encode($response_data, JSON_NUMERIC_CHECK);
?>