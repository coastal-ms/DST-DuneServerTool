<?php
declare(strict_types=1);
const SNAPSHOT_REFRESH_HOURS = 1;
// Optional presence count. Persist no request IP, headers, names, or game data.
ini_set('display_errors', '0');
umask(0077);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function reply(int $status, array $body): never {
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

try {
    // HTTP visitors can only read the published snapshot. An authenticated
    // hosting SSH session can rebuild it by running this file with --refresh.
    $forceSnapshot = PHP_SAPI === 'cli' && ($argv[1] ?? '') === '--refresh';
    $method = $forceSnapshot ? 'GET' : ($_SERVER['REQUEST_METHOD'] ?? '');
    if (!in_array($method, ['GET', 'POST', 'DELETE'], true)) {
        header('Allow: GET, POST, DELETE');
        reply(405, ['error' => 'Unsupported method.']);
    }
    $localTest = PHP_SAPI === 'cli-server' && in_array($_SERVER['REMOTE_ADDR'] ?? '', ['127.0.0.1', '::1'], true);
    if (($_SERVER['HTTPS'] ?? '') !== 'on' && !$localTest && !$forceSnapshot) {
        reply(400, ['error' => 'HTTPS is required.']);
    }
    $documentRoot = realpath($forceSnapshot ? dirname(__DIR__) : ($_SERVER['DOCUMENT_ROOT'] ?? ''));
    if ($documentRoot === false || $documentRoot === DIRECTORY_SEPARATOR) {
        reply(503, ['error' => 'Count service is not configured.']);
    }
    $directory = getenv('DST_USAGE_DATA_DIR') ?: dirname($documentRoot) . '/.dst-usage-count';
    if (!is_dir($directory) && !mkdir($directory, 0700, true)) {
        throw new RuntimeException('Storage unavailable.');
    }
    $directory = realpath($directory);
    if ($directory === false || $directory === $documentRoot || str_starts_with($directory, $documentRoot . DIRECTORY_SEPARATOR)) {
        reply(503, ['error' => 'Count storage must be outside the public website.']);
    }
    $database = $directory . '/presence.sqlite';
    $db = new PDO('sqlite:' . $database, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 3]);
    $db->exec('PRAGMA journal_mode=WAL');
    $db->exec('CREATE TABLE IF NOT EXISTS presence (id_hash TEXT PRIMARY KEY, token_hash TEXT NOT NULL, edition TEXT NOT NULL, version TEXT NOT NULL, seen_at INTEGER NOT NULL)');
    $now = time();
    if ($method === 'GET') {
        $snapshotPath = $directory . '/snapshot.json';
        $lock = fopen($directory . '/snapshot.lock', 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) { throw new RuntimeException('Snapshot unavailable.'); }
        $snapshot = is_file($snapshotPath) ? json_decode((string)file_get_contents($snapshotPath), true) : null;
        if (!$forceSnapshot && is_array($snapshot) && ($snapshot['protocol'] ?? null) === 1 &&
            ($snapshot['basis'] ?? null) === 'confirmed-installations' &&
            ($snapshot['refreshHours'] ?? null) === SNAPSHOT_REFRESH_HOURS &&
            is_int($snapshot['updatedAt'] ?? null) && $snapshot['updatedAt'] <= $now &&
            $snapshot['updatedAt'] > $now - SNAPSHOT_REFRESH_HOURS * 3600) {
            flock($lock, LOCK_UN); fclose($lock);
            reply(200, $snapshot);
        }
        $query = $db->query('SELECT edition, count(*) AS total FROM presence GROUP BY edition');
        $counts = ['windows' => 0, 'docker' => 0];
        foreach ($query as $row) { $counts[$row['edition']] = (int)$row['total']; }
        $snapshot = ['protocol' => 1, 'basis' => 'confirmed-installations', 'refreshHours' => SNAPSHOT_REFRESH_HOURS, 'updatedAt' => $now,
                     'total' => array_sum($counts), 'windows' => $counts['windows'], 'docker' => $counts['docker']];
        $temporary = $snapshotPath . '.' . bin2hex(random_bytes(8)) . '.tmp';
        if (file_put_contents($temporary, json_encode($snapshot), LOCK_EX) === false || !rename($temporary, $snapshotPath)) {
            throw new RuntimeException('Snapshot could not be stored.');
        }
        flock($lock, LOCK_UN); fclose($lock);
        reply(200, $snapshot);
    }
    if (($_SERVER['CONTENT_TYPE'] ?? '') === '' || !preg_match('/^application\/json(?:\s*;|$)/i', $_SERVER['CONTENT_TYPE'])) {
        reply(415, ['error' => 'Expected JSON.']);
    }
    $raw = file_get_contents('php://input', false, null, 0, 1025);
    if ($raw === false || strlen($raw) > 1024) { reply(413, ['error' => 'Report too large.']); }
    try { $body = json_decode($raw, true, 8, JSON_THROW_ON_ERROR); }
    catch (JsonException $error) { reply(400, ['error' => 'Invalid report.']); }
    $keys = $method === 'POST' ? ['id', 'edition', 'version'] : ['id'];
    if (!is_array($body) || count($body) !== count($keys) || array_diff(array_keys($body), $keys) || array_diff($keys, array_keys($body))) {
        reply(400, ['error' => 'Only installation ID, edition and app version are accepted.']);
    }
    if (!is_string($body['id']) || !preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $body['id'])) {
        reply(400, ['error' => 'Invalid installation ID.']);
    }
    if ($method === 'POST' && (!in_array($body['edition'], ['windows', 'docker'], true) ||
        !is_string($body['version']) || !preg_match('/^(?:unknown|[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-+][A-Za-z0-9.-]+)?)$/D', $body['version']) || strlen($body['version']) > 80)) {
        reply(400, ['error' => 'Invalid edition or version.']);
    }
    $authorization = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
    if (!preg_match('/^Bearer ([a-f0-9]{64})$/D', $authorization, $match)) { reply(401, ['error' => 'Reporting token required.']); }
    $idHash = hash('sha256', $body['id']);
    $tokenHash = hash('sha256', $match[1]);
    $db->exec('BEGIN IMMEDIATE');
    try {
        $find = $db->prepare('SELECT token_hash FROM presence WHERE id_hash = ?');
        $find->execute([$idHash]);
        $existing = $find->fetchColumn();
        if ($existing !== false && !hash_equals($existing, $tokenHash)) {
            $db->exec('ROLLBACK'); reply(403, ['error' => 'Reporting token does not match.']);
        }
        if ($method === 'DELETE') {
            $delete = $db->prepare('DELETE FROM presence WHERE id_hash = ?'); $delete->execute([$idHash]);
        } else {
            // One row per installation; repeated reports cannot increase its count.
            if ($existing !== false) {
                $update = $db->prepare('UPDATE presence SET edition=?, version=?, seen_at=? WHERE id_hash=?');
                $update->execute([$body['edition'], $body['version'], $now, $idHash]);
            } else {
                $insert = $db->prepare('INSERT INTO presence (id_hash, token_hash, edition, version, seen_at) VALUES (?, ?, ?, ?, ?)');
                $insert->execute([$idHash, $tokenHash, $body['edition'], $body['version'], $now]);
            }
        }
        $db->exec('COMMIT');
    } catch (Throwable $error) {
        try { $db->exec('ROLLBACK'); } catch (Throwable $ignored) {}
        throw $error;
    }
    reply(200, ['accepted' => true]);
} catch (Throwable $error) {
    // Never send storage paths, IDs, tokens or exception details to clients.
    reply(503, ['error' => 'Count service temporarily unavailable.']);
}
