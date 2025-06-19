<?php
// /var/www/html/sla_status/api/submit_metrics.php

$db_file = '/opt/sla_monitor/central_sla_data.sqlite'; 
$log_file_api = '/var/log/sla_api.log'; 
$central_config_file_path = '/opt/sla_monitor/sla_config.env'; // For default thresholds

function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[SubmitMetrics] ' . $message . PHP_EOL, FILE_APPEND);
}

function parse_env_file($filepath) { /* Same as before */ 
    $env_vars = []; if (!file_exists($filepath) || !is_readable($filepath)) { api_log("ERROR: Config file {$filepath} not found or not readable."); return $env_vars; }
    $lines = file($filepath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES); foreach ($lines as $line) { $line = trim($line); if (empty($line) || strpos($line, '#') === 0) { continue; } if (strpos($line, '=') !== false) { list($name, $value) = explode('=', $line, 2); $name = trim($name); $value = trim($value); if (preg_match('/^(\'(.*)\'|"(.*)")$/', $value, $matches)) { $value = isset($matches[3]) ? $matches[3] : $matches[2]; } $env_vars[$name] = $value; } } return $env_vars;
}

header("Content-Type: application/json");
// TODO: Implement robust API Key Authentication here

$input_data = json_decode(file_get_contents('php://input'), true);

if (!$input_data || !isset($input_data['timestamp']) || !isset($input_data['agent_identifier']) || !isset($input_data['agent_type'])) {
    http_response_code(400); api_log("Invalid data: missing timestamp, agent_identifier, or agent_type. Payload: " . file_get_contents('php://input'));
    echo json_encode(['status' => 'error', 'message' => 'Invalid data: missing timestamp, agent_identifier, or agent_type.']); exit;
}

$agent_identifier = filter_var($input_data['agent_identifier'], FILTER_SANITIZE_STRING);
$timestamp = $input_data['timestamp']; 
$agent_hostname = filter_var($input_data['agent_hostname'] ?? 'unknown_host', FILTER_SANITIZE_STRING);
$agent_source_ip = filter_var($input_data['agent_source_ip'] ?? 'unknown_ip', FILTER_VALIDATE_IP) ?: 'invalid_ip';
$agent_type_received = filter_var($input_data['agent_type'], FILTER_SANITIZE_STRING);
if (!in_array($agent_type_received, ['ISP', 'Client'])) { $agent_type_received = 'Client'; /* Default to client if invalid type sent */ }

api_log("Received metrics from agent: " . $agent_identifier . " (Type: $agent_type_received) for timestamp: " . $timestamp);

try {
    if (!file_exists(dirname($db_file))) { mkdir(dirname($db_file), 0770, true); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE | SQLITE3_OPEN_CREATE);
    $db->exec("PRAGMA journal_mode=WAL;");

    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE agent_identifier = :agent_id LIMIT 1");
    $stmt_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
    $profile_result = $stmt_profile->execute();
    $profile_row = $profile_result->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();

    $isp_profile_id = null;
    $current_time_utc = gmdate("Y-m-d\TH:i:s\Z");

    if (!$profile_row || !isset($profile_row['id'])) {
        api_log("Agent identifier '{$agent_identifier}' not found. Auto-creating profile with defaults...");
        $defaults = parse_env_file($central_config_file_path); // Get defaults from central config

        $stmt_create_profile = $db->prepare("
            INSERT INTO isp_profiles (
                agent_name, agent_identifier, agent_type, 
                last_reported_hostname, last_reported_source_ip, last_heard_from, is_active,
                sla_target_percentage, rtt_degraded, rtt_poor, loss_degraded, loss_poor, 
                ping_jitter_degraded, ping_jitter_poor, dns_time_degraded, dns_time_poor, 
                http_time_degraded, http_time_poor, speedtest_dl_degraded, speedtest_dl_poor, 
                speedtest_ul_degraded, speedtest_ul_poor, teams_webhook_url, alert_hostname_override
            ) VALUES (
                :name, :agent_id, :type, 
                :host, :ip, :now, 1,
                :sla_target, :rtt_d, :rtt_p, :loss_d, :loss_p, 
                :pjd, :pjp, :dns_d, :dns_p, 
                :http_d, :http_p, :dl_d, :dl_p, 
                :ul_d, :ul_p, :teams, :alert_host
            )");
        
        $default_agent_name = !empty($agent_hostname) && $agent_hostname !== 'unknown_host' ? $agent_hostname : $agent_identifier;
        $stmt_create_profile->bindValue(':name', $default_agent_name, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':type', $agent_type_received, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':host', $agent_hostname, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':ip', $agent_source_ip, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':now', $current_time_utc, SQLITE3_TEXT);
        
        $stmt_create_profile->bindValue(':sla_target', (float)($defaults['DEFAULT_PROFILE_SLA_TARGET_PERCENTAGE'] ?? 99.5), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':rtt_d', (int)($defaults['DEFAULT_PROFILE_RTT_DEGRADED'] ?? 100), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':rtt_p', (int)($defaults['DEFAULT_PROFILE_RTT_POOR'] ?? 250), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':loss_d', (int)($defaults['DEFAULT_PROFILE_LOSS_DEGRADED'] ?? 2), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':loss_p', (int)($defaults['DEFAULT_PROFILE_LOSS_POOR'] ?? 10), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':pjd', (int)($defaults['DEFAULT_PROFILE_PING_JITTER_DEGRADED'] ?? 30), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':pjp', (int)($defaults['DEFAULT_PROFILE_PING_JITTER_POOR'] ?? 50), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':dns_d', (int)($defaults['DEFAULT_PROFILE_DNS_TIME_DEGRADED'] ?? 300), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':dns_p', (int)($defaults['DEFAULT_PROFILE_DNS_TIME_POOR'] ?? 800), SQLITE3_INTEGER);
        $stmt_create_profile->bindValue(':http_d', (float)($defaults['DEFAULT_PROFILE_HTTP_TIME_DEGRADED'] ?? 1.0), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':http_p', (float)($defaults['DEFAULT_PROFILE_HTTP_TIME_POOR'] ?? 2.5), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':dl_d', (float)($defaults['DEFAULT_PROFILE_SPEEDTEST_DL_DEGRADED'] ?? 60), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':dl_p', (float)($defaults['DEFAULT_PROFILE_SPEEDTEST_DL_POOR'] ?? 30), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':ul_d', (float)($defaults['DEFAULT_PROFILE_SPEEDTEST_UL_DEGRADED'] ?? 20), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':ul_p', (float)($defaults['DEFAULT_PROFILE_SPEEDTEST_UL_POOR'] ?? 5), SQLITE3_FLOAT);
        $stmt_create_profile->bindValue(':teams', ($defaults['DEFAULT_PROFILE_TEAMS_WEBHOOK_URL'] ?? ''), SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':alert_host', $agent_hostname, SQLITE3_TEXT); // Default alert hostname to agent's

        if (!$stmt_create_profile->execute()) { throw new Exception("Failed to auto-create profile for '{$agent_identifier}': " . $db->lastErrorMsg()); }
        $isp_profile_id = $db->lastInsertRowID();
        api_log("Auto-created profile for agent '{$agent_identifier}' with ID: {$isp_profile_id}");
        $stmt_create_profile->close();
    } else {
        $isp_profile_id = (int)$profile_row['id'];
        $update_stmt = $db->prepare("UPDATE isp_profiles SET last_heard_from = :now, last_reported_hostname = :hostname, last_reported_source_ip = :source_ip, agent_type = :agent_type WHERE id = :isp_id");
        $update_stmt->bindValue(':now', $current_time_utc, SQLITE3_TEXT);
        $update_stmt->bindValue(':hostname', $agent_hostname, SQLITE3_TEXT);
        $update_stmt->bindValue(':source_ip', $agent_source_ip, SQLITE3_TEXT);
        $update_stmt->bindValue(':agent_type', $agent_type_received, SQLITE3_TEXT); // Update agent type if it changed
        $update_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
        $update_stmt->execute(); $update_stmt->close();
    }
    
    $overall_connectivity = $input_data['overall_connectivity'] ?? null; /* ... (rest of value extraction like before) ... */
    $avg_rtt_ms = (isset($input_data['ping_summary']['average_rtt_ms']) && is_numeric($input_data['ping_summary']['average_rtt_ms'])) ? (float)$input_data['ping_summary']['average_rtt_ms'] : null; $avg_loss_percent = (isset($input_data['ping_summary']['average_packet_loss_percent']) && is_numeric($input_data['ping_summary']['average_packet_loss_percent'])) ? (float)$input_data['ping_summary']['average_packet_loss_percent'] : null; $avg_jitter_ms = (isset($input_data['ping_summary']['average_jitter_ms']) && is_numeric($input_data['ping_summary']['average_jitter_ms'])) ? (float)$input_data['ping_summary']['average_jitter_ms'] : null; $dns_status = $input_data['dns_resolution']['status'] ?? null; $dns_resolve_time_ms = (isset($input_data['dns_resolution']['resolve_time_ms']) && is_numeric($input_data['dns_resolution']['resolve_time_ms'])) ? (int)$input_data['dns_resolution']['resolve_time_ms'] : null; $http_status = $input_data['http_check']['status'] ?? null; $http_response_code = (isset($input_data['http_check']['response_code']) && is_numeric($input_data['http_check']['response_code'])) ? (int)$input_data['http_check']['response_code'] : null; $http_total_time_s = (isset($input_data['http_check']['total_time_s']) && is_numeric($input_data['http_check']['total_time_s'])) ? (float)$input_data['http_check']['total_time_s'] : null; $st_status = $input_data['speed_test']['status'] ?? null; $st_dl = (isset($input_data['speed_test']['download_mbps']) && is_numeric($input_data['speed_test']['download_mbps'])) ? (float)$input_data['speed_test']['download_mbps'] : null; $st_ul = (isset($input_data['speed_test']['upload_mbps']) && is_numeric($input_data['speed_test']['upload_mbps'])) ? (float)$input_data['speed_test']['upload_mbps'] : null; $st_ping = (isset($input_data['speed_test']['ping_ms']) && is_numeric($input_data['speed_test']['ping_ms'])) ? (float)$input_data['speed_test']['ping_ms'] : null; $st_jitter = (isset($input_data['speed_test']['jitter_ms']) && is_numeric($input_data['speed_test']['jitter_ms'])) ? (float)$input_data['speed_test']['jitter_ms'] : null; $detailed_health_summary = $input_data['detailed_health_summary'] ?? null; $sla_met_interval = (isset($input_data['current_sla_met_status']) && $input_data['current_sla_met_status'] === 'MET') ? 1 : 0;

    $stmt = $db->prepare("INSERT OR IGNORE INTO sla_metrics (isp_profile_id, timestamp, overall_connectivity, avg_rtt_ms, avg_loss_percent, avg_jitter_ms, dns_status, dns_resolve_time_ms, http_status, http_response_code, http_total_time_s, speedtest_status, speedtest_download_mbps, speedtest_upload_mbps, speedtest_ping_ms, speedtest_jitter_ms, detailed_health_summary, sla_met_interval) VALUES (:isp_id, :ts, :conn, :rtt, :loss, :jitter, :dns_stat, :dns_time, :http_stat, :http_code, :http_time, :st_stat, :st_dl, :st_ul, :st_ping, :st_jit, :health, :sla_met)");
    $stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER); $stmt->bindValue(':ts', $timestamp, SQLITE3_TEXT); $stmt->bindValue(':conn', $overall_connectivity, SQLITE3_TEXT); $stmt->bindValue(':rtt', $avg_rtt_ms, $avg_rtt_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':loss', $avg_loss_percent, $avg_loss_percent === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':jitter', $avg_jitter_ms, $avg_jitter_ms === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':dns_stat', $dns_status, SQLITE3_TEXT); $stmt->bindValue(':dns_time', $dns_resolve_time_ms, $dns_resolve_time_ms === null ? SQLITE3_NULL : SQLITE3_INTEGER); $stmt->bindValue(':http_stat', $http_status, SQLITE3_TEXT); $stmt->bindValue(':http_code', $http_response_code, $http_response_code === null ? SQLITE3_NULL : SQLITE3_INTEGER); $stmt->bindValue(':http_time', $http_total_time_s, $http_total_time_s === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_stat', $st_status, SQLITE3_TEXT); $stmt->bindValue(':st_dl', $st_dl, $st_dl === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_ul', $st_ul, $st_ul === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_ping', $st_ping, $st_ping === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':st_jit', $st_jitter, $st_jitter === null ? SQLITE3_NULL : SQLITE3_FLOAT); $stmt->bindValue(':health', $detailed_health_summary, SQLITE3_TEXT); $stmt->bindValue(':sla_met', $sla_met_interval, SQLITE3_INTEGER);
    $result = $stmt->execute();

    if ($result) { api_log("OK: Metrics inserted for agent: {$agent_identifier} (Profile ID: {$isp_profile_id})"); echo json_encode(['status' => 'success', 'message' => 'Metrics received for agent ' . $agent_identifier, 'isp_profile_id' => $isp_profile_id]);
    } else { throw new Exception("Failed to insert metrics data: " . $db->lastErrorMsg()); }
    $stmt->close(); $db->close();
} catch (Exception $e) { api_log("ERROR for agent {$agent_identifier}: " . $e->getMessage()); http_response_code(500); echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]); }
?>