<?php
// /var/www/html/sla_status/api/submit_metrics.php

// These would be ideal candidates to move to a central 'config.php' or 'bootstrap.php'
$db_file = '/opt/sla_monitor/central_sla_data.sqlite'; 
$log_file_api = '/var/log/sla_api.log'; 
$central_config_file_path = '/opt/sla_monitor/sla_config.env';

function api_log($message) {
    file_put_contents($GLOBALS['log_file_api'], date('[Y-m-d H:i:s T] ') . '[SubmitMetrics] ' . $message . PHP_EOL, FILE_APPEND);
}

function parse_env_file($filepath) {
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

// --- FIX 1: Use safer input sanitization ---
$agent_identifier = htmlspecialchars($input_data['agent_identifier'], ENT_QUOTES, 'UTF-8');
$timestamp = $input_data['timestamp']; 
$agent_hostname = htmlspecialchars($input_data['agent_hostname'] ?? 'unknown_host', ENT_QUOTES, 'UTF-8');
$agent_source_ip = filter_var($input_data['agent_source_ip'] ?? 'unknown_ip', FILTER_VALIDATE_IP) ?: 'invalid_ip';
$agent_type_received = htmlspecialchars($input_data['agent_type'], ENT_QUOTES, 'UTF-8');
if (!in_array($agent_type_received, ['ISP', 'Client'])) { $agent_type_received = 'Client'; }

api_log("Received metrics from agent: " . $agent_identifier . " (Type: $agent_type_received) for timestamp: " . $timestamp);

$db = null; // Define DB handle outside try block for rollback access
try {
    // --- FIX 3: API should NOT create its own database/directory ---
    // The setup script is responsible for this. The API should fail if the DB doesn't exist.
    if (!file_exists($db_file)) {
        throw new Exception("Database file not found at {$db_file}. The server environment is not correctly configured.");
    }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE); // Must be writable, no need for create
    $db->exec("PRAGMA journal_mode=WAL;");

    // --- FIX 2: Use a transaction to prevent race conditions ---
    $db->exec('BEGIN IMMEDIATE TRANSACTION');

    $stmt_profile = $db->prepare("SELECT id FROM isp_profiles WHERE agent_identifier = :agent_id LIMIT 1");
    $stmt_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
    $profile_result = $stmt_profile->execute();
    $profile_row = $profile_result->fetchArray(SQLITE3_ASSOC);
    $stmt_profile->close();

    $isp_profile_id = null;
    $current_time_utc = gmdate("Y-m-d\TH:i:s\Z");

    if (!$profile_row) {
        api_log("Agent identifier '{$agent_identifier}' not found. Auto-creating profile with defaults...");
        // Auto-creation logic (largely the same, just inside a transaction)
        $defaults = parse_env_file($central_config_file_path);
        $stmt_create_profile = $db->prepare("INSERT INTO isp_profiles (agent_name, agent_identifier, agent_type, last_reported_hostname, last_reported_source_ip, last_heard_from, is_active, sla_target_percentage, rtt_degraded, rtt_poor, loss_degraded, loss_poor, ping_jitter_degraded, ping_jitter_poor, dns_time_degraded, dns_time_poor, http_time_degraded, http_time_poor, speedtest_dl_degraded, speedtest_dl_poor, speedtest_ul_degraded, speedtest_ul_poor, teams_webhook_url, alert_hostname_override) VALUES (:name, :agent_id, :type, :host, :ip, :now, 1, :sla_target, :rtt_d, :rtt_p, :loss_d, :loss_p, :pjd, :pjp, :dns_d, :dns_p, :http_d, :http_p, :dl_d, :dl_p, :ul_d, :ul_p, :teams, :alert_host)");
        
        $default_agent_name = ($agent_hostname !== 'unknown_host') ? $agent_hostname : $agent_identifier;
        $stmt_create_profile->bindValue(':name', $default_agent_name, SQLITE3_TEXT);
        // ... (all other bindValue calls are the same) ...
        $stmt_create_profile->bindValue(':agent_id', $agent_identifier, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':type', $agent_type_received, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':host', $agent_hostname, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':ip', $agent_source_ip, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':now', $current_time_utc, SQLITE3_TEXT);
        $stmt_create_profile->bindValue(':sla_target', (float)($defaults['DEFAULT_PROFILE_SLA_TARGET_PERCENTAGE'] ?? 99.5));
        // (the rest of the default binds are fine)

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
        $update_stmt->bindValue(':agent_type', $agent_type_received, SQLITE3_TEXT);
        $update_stmt->bindValue(':isp_id', $isp_profile_id, SQLITE3_INTEGER);
        $update_stmt->execute(); 
        $update_stmt->close();
    }

    // --- FIX 4: Improved Readability ---
    // Helper function to safely extract numeric values
    function get_numeric($data, $key, $is_float = false) {
        return (isset($data[$key]) && is_numeric($data[$key])) ? ($is_float ? (float)$data[$key] : (int)$data[$key]) : null;
    }
    
    $overall_connectivity = $input_data['overall_connectivity'] ?? null;
    $avg_rtt_ms = get_numeric($input_data['ping_summary'] ?? [], 'average_rtt_ms', true);
    $avg_loss_percent = get_numeric($input_data['ping_summary'] ?? [], 'average_packet_loss_percent', true);
    $avg_jitter_ms = get_numeric($input_data['ping_summary'] ?? [], 'average_jitter_ms', true);
    $dns_status = $input_data['dns_resolution']['status'] ?? null;
    $dns_resolve_time_ms = get_numeric($input_data['dns_resolution'] ?? [], 'resolve_time_ms');
    // (and so on for the rest of the variables...)
    
    // The INSERT OR IGNORE statement for metrics is good.
    $stmt = $db->prepare("INSERT OR IGNORE INTO sla_metrics (isp_profile_id, timestamp, ...) VALUES (:isp_id, :ts, ...)");
    // ... all your bindValue calls are correct ...
    $result = $stmt->execute();
    $stmt->close();

    // --- FIX 2 (Continued): Commit the transaction if everything succeeded ---
    $db->exec('COMMIT');
    
    api_log("OK: Metrics processed for agent: {$agent_identifier} (Profile ID: {$isp_profile_id})");
    echo json_encode(['status' => 'success', 'message' => 'Metrics received for agent ' . $agent_identifier, 'isp_profile_id' => $isp_profile_id]);
    
} catch (Exception $e) {
    // --- FIX 2 (Continued): Rollback transaction on any error ---
    if ($db) {
        $db->exec('ROLLBACK');
    }
    api_log("FATAL ERROR for agent {$agent_identifier}: " . $e->getMessage());
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Server error: ' . $e->getMessage()]);
} finally {
    if ($db) {
        $db->close();
    }
}
?>