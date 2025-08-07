<?php
// create_admin.php
// A one-time script to create an admin user.
// DELETE THIS FILE AFTER USE FOR SECURITY.

ini_set('display_errors', 1);
error_reporting(E_ALL);

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';

// --- Simple HTML Form ---
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo <<<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Create Admin User</title>
    <style>
        body { font-family: sans-serif; background-color: #f2f2f2; display: flex; justify-content: center; align-items: center; height: 100vh; }
        form { background-color: white; padding: 2em; border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
        input { display: block; width: 100%; padding: 0.8em; margin-bottom: 1em; border: 1px solid #ccc; border-radius: 4px; }
        button { width: 100%; padding: 1em; background-color: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        .error { color: red; margin-bottom: 1em; }
        .success { color: green; margin-bottom: 1em; }
    </style>
</head>
<body>
    <form action="create_admin.php" method="post">
        <h2>Create Admin User</h2>
        <p>This script creates the initial admin user. For security, please delete this file immediately after use.</p>
        <label for="username">Username:</label>
        <input type="text" id="username" name="username" required>
        <label for="password">Password:</label>
        <input type="password" id="password" name="password" required>
        <button type="submit">Create User</button>
    </form>
</body>
</html>
HTML;
    exit;
}

// --- Handle Form Submission ---
$username = trim($_POST['username'] ?? '');
$password = trim($_POST['password'] ?? '');

if (empty($username) || empty($password)) {
    die("Error: Username and password cannot be empty.");
}

try {
    if (!file_exists($db_file)) {
        throw new Exception("Database file not found at {$db_file}. Please run the main setup script first.");
    }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READWRITE);
    $db->exec("PRAGMA journal_mode=WAL;");

    // Check if users table exists
    $table_check = $db->querySingle("SELECT name FROM sqlite_master WHERE type='table' AND name='users'");
    if (!$table_check) {
        throw new Exception("The 'users' table does not exist. Please run the main setup script to create it.");
    }

    // Hash the password securely
    $password_hash = password_hash($password, PASSWORD_ARGON2ID);
    if ($password_hash === false) {
        throw new Exception("Failed to hash password.");
    }

    // Insert the new user
    $stmt = $db->prepare("INSERT OR REPLACE INTO users (username, password_hash) VALUES (:username, :hash)");
    $stmt->bindValue(':username', $username, SQLITE3_TEXT);
    $stmt->bindValue(':hash', $password_hash, SQLITE3_TEXT);
    
    if ($stmt->execute()) {
        echo "<p class='success'>Admin user '{$username}' created successfully. You may now log in.</p>";
        echo "<p style='font-weight:bold; color:red;'>IMPORTANT: Please delete this file (create_admin.php) immediately!</p>";
    } else {
        throw new Exception("Failed to insert user into database: " . $db->lastErrorMsg());
    }

    $db->close();

} catch (Exception $e) {
    http_response_code(500);
    echo "<p class='error'>Error: " . $e->getMessage() . "</p>";
}
?>
