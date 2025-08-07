<?php
// auth.php
// Handles user authentication.

ini_set('display_errors', 0);
ini_set('log_errors', 1);
session_start();

// --- Configuration ---
$db_file = '/opt/sla_monitor/central_sla_data.sqlite';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: login.php');
    exit;
}

$username = trim($_POST['username'] ?? '');
$password = trim($_POST['password'] ?? '');

if (empty($username) || empty($password)) {
    $_SESSION['login_error'] = 'Username and password are required.';
    header('Location: login.php');
    exit;
}

try {
    if (!file_exists($db_file)) { throw new Exception("Database file not found."); }
    $db = new SQLite3($db_file, SQLITE3_OPEN_READONLY);

    $stmt = $db->prepare("SELECT id, password_hash FROM users WHERE username = :username LIMIT 1");
    $stmt->bindValue(':username', $username, SQLITE3_TEXT);
    $result = $stmt->execute()->fetchArray(SQLITE3_ASSOC);
    $stmt->close();
    $db->close();

    if ($result && password_verify($password, $result['password_hash'])) {
        // Password is correct, start the session.
        session_regenerate_id(true); // Prevent session fixation
        $_SESSION['user_id'] = $result['id'];
        $_SESSION['username'] = $username;
        header('Location: index.html');
        exit;
    } else {
        // Invalid credentials
        $_SESSION['login_error'] = 'Invalid username or password.';
        header('Location: login.php');
        exit;
    }

} catch (Exception $e) {
    error_log("Authentication error: " . $e->getMessage());
    $_SESSION['login_error'] = 'A server error occurred. Please try again later.';
    header('Location: login.php');
    exit;
}
?>
