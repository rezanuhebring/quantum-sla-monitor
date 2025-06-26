<?php
// /var/www/html/sla_status/api/submit_metrics.php

$db_file = '/opt/sla_monitor/central_sla_data.sqlite'; 
$log_file_api = '/var/log/sla_api.log'; 

function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[SubmitMetrics] ' . $message . PHP_EOL, FILE_APPEND);
}

header("Content-Type: application/json");

$input_data = json_decode(file_get_contents('php://input'), true);

if (!$input_data || !isset($input_data['timestamp']) || !isset($input_data['agent_identifier'])) {
    http_response_code(400); api_log("Invalid data: missing timestamp or agent_identifier. Payload: " . file_get_contents('php://input'));
    echo json_encode(['status' => 'error', 'message' => 'Invalid data: missing timestamp or agent_identifier.']);
    exit;
}

$agent_identifier = htmlspecialchars($input_data['agent_identifier'], ENT_QUOTES, 'UTF-8');
$timestamp = $input_data['timestamp'];
$agent_hostname = htmlspecialchars($input_data['agent_hostname'] ?? 'unknown_host', ENT_QUOTES, 'UTF-8');
$agent_source_ip = filter_var($input_data['agent_source_ip'] ?? 'unknown_ip', FILTER_VALIDATE_IP) ?: 'invalid_ip';
$agent_type_received = htmlspecialchars($input_data['agent_type'] ?? 'Client', ENT_QUOTES, 'UTF-8');
if (!in_array($agent_type_received, ['ISP', 'Client'])) { $agent_type_received = 'Client'; }

api_log("Received metrics from agent: " . $agent_identifier);

$db = null;
try {
    if (!file_exists($db_file)) {
        throw new Exception("Database file not found at {$db_file}. The server environment is not correctly configured.");
    }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE);
    $db->exec("PRAGMA journal_mode=WAL;");
    $db->exec('BEGIN IMMEDIATE TRANSACTION');

    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE agent_identifier = :agent_id LIMIT 1");
    $stmt_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
    $profile_result = $stmt_profile->execute();
    $profile_row = $profile_result->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();

    $isp_profile_id = null;
    $current_time_utc = gmdate("Y-m-d\TH:i:s\Z");

    if (!$profile_row) {
        // Auto-create profile logic is complex but assumed correct from prior versions
        api_log("Agent identifier '{$agent_identifier}' not found. Auto-creating profile.");
        // For simplicity, we'll use a basic insert. The more complex one from before is fine too.
        $stmt_create_profile = $db->prepare("INSERT INTO isp_profiles (agent_name, agent_identifier, agent_type, last_reported_hostname, last_reported_source_ip, last_heard_from) VALUES (:name, :agent_id, :type, :host, :ip, :now)");
        $stmt_create_profile->bindValue(':name', ($agent_hostname !== 'unknown_host' ? $agent_hostname : $agent_identifier));
        $stmt_create_profile->bindValue(':agent_id', $agent_identifier);
        $stmt_create_profile->bindValue(':type', $agent_type_received);
        $stmt_create_profile->bindValue(':host', $agent_hostname);
        $stmt_create_profile->bindValue(':ip', $agent_source_ip);
        $stmt_create_profile->bindValue(':now', $current_time_utc);
        $stmt_create_profile->execute();
        $isp_profile_id = $db->lastInsertRowID();
        $stmt_create_profile->close();
    } else {
        $isp_profile_id = (int)$profile_row['id'];
        $update_stmt = $db->prepare("UPDATE isp_profiles SET last_heard_from = :now, last_reported_hostname = :hostname, last_reported_source_ip = :source_ip WHERE id = :isp_id");
        $update_stmt->bindValue(':now', $current_time_utc);
        $update_stmt->bindValue(':hostname', $agent_hostname);
        $update_stmt->bindValue(':source_ip', $agent_source_ip);
        $update_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
        $update_stmt->execute();
        $update_stmt->close();
    }
    
    // Helper function to safely get nested values
    function get_nested_value($array, $keys, $type = 'text') {
        $current = $array;
        foreach ($keys as $key) {
            if (!isset($current[$key])) return null;
            $current = $current[$key];
        }
        if ($current === 'N/A' || $current === '') return null;
        return $type === 'float' ? (float)$current : ($type === 'int' ? (int)$current : $current);
    }

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
    
    // *** THIS IS THE CORRECTED SQL STATEMENT ***
    $stmt = $db->prepare("
        INSERT OR IGNORE INTO sla_metrics (
            isp_profile_id, timestamp, overall_connectivity, 
            avg_rtt_ms, avg_loss_percent, avg_jitter_ms, 
            dns_status, dns_resolve_time_ms, 
            http_status, http_response_code, http_total_time_s, 
            speedtest_status, speedtest_download_mbps, speedtest_upload_mbps, 
            speedtest_ping_ms, speedtest_jitter_ms
        ) VALUES (
            :isp_id, :ts, :conn, 
            :rtt, :loss, :jitter,
            :dns_stat, :dns_time,
            :http_stat, :http_code, :http_time,
            :st_stat, :st_dl, :st_ul,
            :st_ping, :st_jit
        )
    ");

    $stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
    $stmt->bindValue(':ts', $timestamp, SQLITE3_TEXT);
    $stmt->bindValue(':conn', $ping_status, SQLITE3_TEXT);
    $stmt->bindValue(':rtt', $avg_rtt_ms, $avg_rtt_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':loss', $avg_loss_percent, $avg_loss_percent === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':jitter', $avg_jitter_ms, $avg_jitter_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':dns_stat', $dns_status, SQLITE3_TEXT);
    $stmt->bindValue(':dns_time', $dns_resolve_time_ms, $dns_resolve_time_ms === null ? SQLITE3_NULL : SQLITE3_INTEGER);
    $stmt->bindValue(':http_stat', $http_status, SQLITE3_TEXT);
    $stmt->bindValue(':http_code', $http_response_code, $http_response_code === null ? SQLITE3_NULL : SQLITE3_INTEGER);
    $stmt->bindValue(':http_time', $http_total_time_s, $http_total_time_s === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':st_stat', $st_status, SQLITE3_TEXT);
    $stmt->bindValue(':st_dl', $st_dl, $st_dl === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':st_ul', $st_ul, $st_ul === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':st_ping', $st_ping, $st_ping === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    $stmt->bindValue(':st_jit', $st_jitter, $st_jitter === null ? SQLITE3_NULL : SQLITE3_FLOAT);
    
    $result = $stmt->execute();

    if ($result) {
        $db->exec('COMMIT');
        api_log("OK: Metrics inserted for agent: {$agent_identifier}");
        echo json_encode(['status' => 'success', 'message' => 'Metrics received for agent ' . $agent_identifier]);
    } else {
        throw new Exception("Failed to insert metrics data: " . $db->lastErrorMsg());
    }
    $stmt->close();
    $db->close();
} catch (Exception $e) {
    if ($db) { $db->exec('ROLLBACK'); }
    api_log("ERROR for agent {$agent_identifier}: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]);
}
?>