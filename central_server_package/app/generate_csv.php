<?php
// generate_csv.php - FINAL PRODUCTION VERSION
// This script dynamically includes the jitter column only if data exists.

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';

// --- Security and Input Validation ---
if (!isset($_GET['isp_id']) || !filter_var($_GET['isp_id'], FILTER_VALIDATE_INT)) {
    http_response_code(400); // Bad Request
    die("Error: Invalid or missing Agent ID provided.");
}
$isp_id = (int)$_GET['isp_id'];

try {
    // --- Database Connection (Read-Only) ---
    if (!file_exists($db_file)) {
        throw new Exception("Central database file not found.");
    }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);
    if (!$db) {
        throw new Exception("Could not connect to the central database.");
    }

    // --- Get Agent Name for Filename ---
    $profile_stmt = $db->prepare("SELECT agent_name FROM isp_profiles WHERE id = :id");
    $profile_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $profile_result = $profile_stmt->execute()->fetchArray(SQLITE3_ASSOC);
    $agent_name = $profile_result ? preg_replace('/[^a-zA-Z0-9_]/', '_', $profile_result['agent_name']) : 'unknown_agent';
    $filename = "sla_history_{$agent_name}.csv";
    $profile_stmt->close();

    // --- Fetch ALL data for the agent into a PHP array ---
    $data_stmt = $db->prepare("SELECT * FROM sla_metrics WHERE isp_profile_id = :id ORDER BY timestamp ASC");
    $data_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $results = $data_stmt->execute();
    if (!$results) {
        throw new Exception("Failed to retrieve metrics for the agent.");
    }
    
    $all_rows = [];
    while ($row = $results->fetchArray(SQLITE3_ASSOC)) {
        $all_rows[] = $row;
    }
    $data_stmt->close();
    $db->close();

    // --- Set HTTP Headers for CSV Download ---
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $filename . '"');
    
    $output = fopen('php://output', 'w');

    if (empty($all_rows)) {
        // If there's no data, just output an empty file or a header row
        fputcsv($output, ['No data available for this agent.']);
        fclose($output);
        exit();
    }

    // --- FIX: Dynamically determine if jitter data exists ---
    $has_jitter_data = false;
    foreach ($all_rows as $row) {
        if (isset($row['speedtest_jitter_ms']) && $row['speedtest_jitter_ms'] !== null && $row['speedtest_jitter_ms'] !== '') {
            $has_jitter_data = true;
            break; // Found it, no need to check further
        }
    }

    // --- Prepare Headers ---
    $headers = array_keys($all_rows[0]);
    if (!$has_jitter_data) {
        // If no jitter data exists anywhere, remove the column from the headers
        $headers = array_filter($headers, function($header) {
            return $header !== 'speedtest_jitter_ms';
        });
    }
    
    // Write the final header row
    fputcsv($output, $headers);

    // --- Write Data Rows ---
    foreach ($all_rows as $row) {
        if (!$has_jitter_data) {
            // If we are in "no jitter" mode, remove the key from the data row too
            unset($row['speedtest_jitter_ms']);
        }
        fputcsv($output, $row);
    }
    
    // --- Clean up ---
    fclose($output);
    exit();

} catch (Exception $e) {
    // FIX: Check if headers have already been sent before trying to send new ones.
    if (!headers_sent()) {
        http_response_code(500); // Internal Server Error
        header('Content-Type: text/plain'); // Reset content type
    }
    // It's crucial to log the actual error for debugging.
    // Using error_log is better than just dying, as it can be directed to a file.
    error_log("CSV Generation Failed: " . $e->getMessage());
    
    // Provide a user-friendly message. Don't expose raw error details unless in a debug mode.
    die("Server Error: Could not generate the CSV file. Please contact an administrator.");
}
?>