<?php
// generate_csv.php
// This script connects to the database, fetches all data for a given agent,
// and streams it to the user as a CSV file.

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

    // --- Set HTTP Headers for CSV Download ---
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $filename . '"');

    // --- Fetch Data ---
    $data_stmt = $db->prepare("
        SELECT * 
        FROM sla_metrics 
        WHERE isp_profile_id = :id 
        ORDER BY timestamp ASC
    ");
    $data_stmt->bindValue(':id', $isp_id, SQLITE3_INTEGER);
    $results = $data_stmt->execute();
    if (!$results) {
        throw new Exception("Failed to retrieve metrics for the agent.");
    }

    // --- Stream CSV to Output ---
    $output = fopen('php://output', 'w');

    // Write Header Row
    $first_row = true;
    while ($row = $results->fetchArray(SQLITE3_ASSOC)) {
        if ($first_row) {
            fputcsv($output, array_keys($row));
            $first_row = false;
        }
        // Write Data Row
        fputcsv($output, $row);
    }

    // If there were no results at all, write the header anyway for an empty file
    if ($first_row) {
        // Query column names if no data rows exist
        $cols_query = $db->query("PRAGMA table_info(sla_metrics)");
        $headers = [];
        while($col = $cols_query->fetchArray(SQLITE3_ASSOC)){
            $headers[] = $col['name'];
        }
        fputcsv($output, $headers);
    }
    
    // --- Clean up ---
    fclose($output);
    $data_stmt->close();
    $db->close();
    exit();

} catch (Exception $e) {
    // If something goes wrong, send an error response instead of a broken file
    http_response_code(500); // Internal Server Error
    header('Content-Type: text/plain'); // Reset content type
    die("Server Error: Could not generate the CSV file. Please check server logs. Details: " . $e->getMessage());
}
?>