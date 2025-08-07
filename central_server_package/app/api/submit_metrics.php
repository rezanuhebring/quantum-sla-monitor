<?php
// submit_metrics.php - FINAL PRODUCTION VERSION
// Correctly handles new summary fields and INSERT/UPDATE logic.

ini_set('display_errors', 0);
ini_set('log_errors', 1);

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';
$log_file_api = '/var/log/sla_api.log';
// Load the API key from environment variables, with a fallback for safety.
$required_api_key = getenv('CENTRAL_API_KEY') ?: '';

// --- Helper Functions ---
function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[SubmitMetrics] ' . $message . PHP_EOL, FILE_APPEND);
}

// --- Main Logic ---
header("Content-Type: application/json");

// --- API Key Authentication ---
$provided_api_key = $_SERVER['HTTP_X_API_KEY'] ?? '';

if (empty($required_api_key) || !hash_equals($required_api_key, $provided_api_key)) {
    http_response_code(401);
    api_log("Unauthorized: Invalid or missing API key. Provided: '{$provided_api_key}'");
    echo json_encode(['status' => 'error', 'message' => 'Unauthorized: Invalid API Key.']);
    exit;
}

$input_data = json_decode(file_get_contents('php://input'), true);

if (!$input_data || !isset($input_data['timestamp']) || !isset($input_data['agent_identifier'])) {
    http_response_code(400); api_log("Invalid data payload: missing timestamp or agent_identifier.");
    echo json_encode(['status' => 'error', 'message' => 'Invalid data: missing timestamp or agent_identifier.']);
    exit;
}

// Sanitize all inputs
$agent_identifier = htmlspecialchars($input_data['agent_identifier'], ENT_QUOTES, 'UTF-8');
$timestamp = $input_data['timestamp'];
$agent_hostname = htmlspecialchars($input_data['agent_hostname'] ?? 'unknown_host', ENT_QUOTES, 'UTF-8');
$agent_source_ip = filter_var($input_data['agent_source_ip'] ?? 'unknown_ip', FILTER_VALIDATE_IP) ?: 'invalid_ip';
$agent_type_received = htmlspecialchars($input_data['agent_type'] ?? 'Client', ENT_QUOTES, 'UTF-8');
if (!in_array($agent_type_received, ['ISP', 'Client'])) { $agent_type_received = 'Client'; }

api_log("Received metrics from agent: " . $agent_identifier);

$db = null;
try {
    if (!file_exists($db_file)) { throw new Exception("Database file not found at {$db_file}."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE);
    $db->exec("PRAGMA journal_mode=WAL;");
    $db->exec('BEGIN IMMEDIATE TRANSACTION');

    // Implement robust INSERT or UPDATE logic
    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE agent_identifier = :agent_id LIMIT 1");
    $stmt_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
    $profile_row = $stmt_profile->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();
    
    $isp_profile_id = null;
    $current_time_utc = gmdate("Y-m-d\TH:i:s\Z");

    if ($profile_row) {
        $isp_profile_id = (int)$profile_row['id'];
        $update_stmt = $db->prepare("UPDATE isp_profiles SET last_heard_from = :now, last_reported_hostname = :hostname, last_reported_source_ip = :source_ip, agent_type = :agent_type WHERE id = :isp_id");
        $update_stmt->bindValue(':now', $current_time_utc); $update_stmt->bindValue(':hostname', $agent_hostname); $update_stmt->bindValue(':source_ip', $agent_source_ip); $update_stmt->bindValue(':agent_type', $agent_type_received); $update_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
        $update_stmt->execute();
        $update_stmt->close();
    } else {
        api_log("Agent identifier '{$agent_identifier}' not found. Auto-creating profile.");
        $stmt_create_profile = $db->prepare("INSERT INTO isp_profiles (agent_name, agent_identifier, agent_type, last_reported_hostname, last_reported_source_ip, last_heard_from, is_active) VALUES (:name, :agent_id, :type, :host, :ip, :now, 1)");
        $default_agent_name = ($agent_hostname !== 'unknown_host' ? $agent_hostname : $agent_identifier);
        $stmt_create_profile->bindValue(':name', $default_agent_name); $stmt_create_profile->bindValue(':agent_id', $agent_identifier); $stmt_create_profile->bindValue(':type', $agent_type_received); $stmt_create_profile->bindValue(':host', $agent_hostname); $stmt_create_profile->bindValue(':ip', $agent_source_ip); $stmt_create_profile->bindValue(':now', $current_time_utc);
        $stmt_create_profile->execute();
        $isp_profile_id = $db->lastInsertRowID();
        $stmt_create_profile->close();
    }
    
    // Helper function to safely get nested values from JSON payload
    function get_nested_value($array, $keys, $type = 'text') { $current = $array; foreach ($keys as $key) { if (!isset($current[$key])) return null; $current = $current[$key]; } if ($current === 'N/A' || $current === '') return null; return $type === 'float' ? (float)$current : ($type === 'int' ? (int)$current : $current); }
    
    // Process all incoming metrics
    $ping_status = get_nested_value($input_data, ['ping_summary', 'status']);
    $avg_rtt_ms = get_nested_value($input_data, ['ping_summary', 'average_rtt_ms'], 'float');
    $avg_loss_percent = get_nested_value($input_data, ['ping_summary', 'average_packet_loss_percent'], 'float');
    $avg_jitter_ms = get_nested_value($input_data, ['ping_summary', 'average_jitter_ms'], 'float');
    $dns_status = get_nested_value($input_data, ['dns_resolution', 'status']);
    $dns_resolve_time_ms = get_nested_value($input_data, ['dns_resolution', 'resolve_time_ms'], 'int');
    $http_status = get_nested_value($input_data, ['http_check', 'status']);
    $http_response_code = get_nested_value($input_data, ['http_check', 'response_code'], 'int');
    $http_total_time_s = get_nested_value($input_data, ['http_check', 'total_time_s'], 'float');
    $st_status = get_nested_value($input_data, ['speed_test', 'status']);
    $st_dl = get_nested_value($input_data, ['speed_test', 'download_mbps'], 'float');
    $st_ul = get_nested_value($input_data, ['speed_test', 'upload_mbps'], 'float');
    $st_ping = get_nested_value($input_data, ['speed_test', 'ping_ms'], 'float');
    $st_jitter = get_nested_value($input_data, ['speed_test', 'jitter_ms'], 'float');
    $detailed_health_summary = htmlspecialchars($input_data['detailed_health_summary'] ?? 'UNKNOWN', ENT_QUOTES, 'UTF-8');
    $sla_met_interval = (isset($input_data['current_sla_met_status']) && $input_data['current_sla_met_status'] === 'MET') ? 1 : 0;
    
    // Insert the new metrics into the database
    $stmt = $db->prepare("INSERT OR IGNORE INTO sla_metrics (isp_profile_id, timestamp, overall_connectivity, avg_rtt_ms, avg_loss_percent, avg_jitter_ms, dns_status, dns_resolve_time_ms, http_status, http_response_code, http_total_time_s, speedtest_status, speedtest_download_mbps, speedtest_upload_mbps, speedtest_ping_ms, speedtest_jitter_ms, detailed_health_summary, sla_met_interval) VALUES (:isp_id, :ts, :conn, :rtt, :loss, :jitter, :dns_stat, :dns_time, :http_stat, :http_code, :http_time, :st_stat, :st_dl, :st_ul, :st_ping, :st_jit, :health, :sla_met)");
    $stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER); $stmt->bindValue(':ts', $timestamp, SQLITE3_TEXT); $stmt->bindValue(':conn', $ping_status, SQLITE3_TEXT); $stmt->bindValue(':rtt', $avg_rtt_ms, $avg_rtt_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':loss', $avg_loss_percent, $avg_loss_percent === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':jitter', $avg_jitter_ms, $avg_jitter_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':dns_stat', $dns_status, SQLITE3_TEXT); $stmt->bindValue(':dns_time', $dns_resolve_time_ms, $dns_resolve_time_ms === null ? SQLITE3_NULL : SQLITE3_INTEGER); $stmt->bindValue(':http_stat', $http_status, SQLITE3_TEXT); $stmt->bindValue(':http_code', $http_response_code, $http_response_code === null ? SQLITE3_NULL : SQLITE3_INTEGER); $stmt->bindValue(':http_time', $http_total_time_s, $http_total_time_s === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_stat', $st_status, SQLITE3_TEXT); $stmt->bindValue(':st_dl', $st_dl, $st_dl === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_ul', $st_ul, $st_ul === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_ping', $st_ping, $st_ping === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_jit', $st_jitter, $st_jitter === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':health', $detailed_health_summary, SQLITE3_TEXT); $stmt->bindValue(':sla_met', $sla_met_interval, SQLITE3_INTEGER);
    
    if ($stmt->execute()) {
        $db->exec('COMMIT');
        api_log("OK: Metrics inserted for agent: {$agent_identifier}");
        echo json_encode(['status' => 'success', 'message' => 'Metrics received for agent ' . $agent_identifier]);
    } else {
        throw new Exception("Failed to insert metrics data: " . $db->lastErrorMsg());
    }
    
} catch (Exception $e) {
    if ($db) { $db->exec('ROLLBACK'); }
    api_log("FATAL ERROR for agent {$agent_identifier}: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]);
} finally {
    if ($db) { $db->close(); }
}
?>