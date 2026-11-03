<?php
// app-api.php — shared by both apps' api.php: request checks, replies, and
// running the app's ctl.sh. Each app's build.sh copies it into web/.
//
// WD's web server runs PHP as root, so this file is the boundary between a
// browser and the NAS (docs/os5-app-lifecycle.md, "Web server"):
// - Only /apps/<package>/ is behind the dashboard login, which WD's nasAdmin
//   checks before Apache runs any PHP. api_guard() refuses every other path,
//   so a copy reachable some other way can't be used without a login.
// - Other websites can't send requests here (CSRF): every call must be a
//   JSON POST with the X-Settings-Request header, which a browser only sends
//   cross-site after a CORS preflight that this server never approves, and
//   an Origin or Referer, when present, must name this host.
// - Input never reaches a shell. ctl.sh runs with a fixed argument list and
//   gets the validated values on stdin, one key=value per line; it checks
//   them again itself.

declare(strict_types=1);

const API_MAX_BODY_BYTES = 16384;
const API_SEARCH_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

/** Send <body> as JSON with HTTP <status>, and end the request. */
function api_reply(array $body, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

/** Refuse the request; <fields> maps form fields to what's wrong with them. */
function api_fail(int $status, string $message, array $fields = []): void
{
    api_reply(['ok' => false, 'error' => $message, 'fields' => (object) $fields], $status);
}

/** "host" or "host:port", lowercased, without the scheme's default port. */
function api_normalize_host(string $host): string
{
    return (string) preg_replace('/:(80|443)$/', '', strtolower(trim($host)));
}

/** The host a URL names (see api_normalize_host), or null if it has none. */
function api_url_host(string $url): ?string
{
    $host = parse_url($url, PHP_URL_HOST);
    if (!is_string($host) || $host === '') {
        return null;
    }
    $port = parse_url($url, PHP_URL_PORT);
    return api_normalize_host(is_int($port) ? "$host:$port" : $host);
}

/** The hosts this request was sent to: Host, and X-Forwarded-Host if a proxy added one. */
function api_request_hosts(): array
{
    $hosts = [];
    foreach (['HTTP_HOST', 'HTTP_X_FORWARDED_HOST'] as $header) {
        foreach (explode(',', $_SERVER[$header] ?? '') as $host) {
            if (trim($host) !== '') {
                $hosts[] = api_normalize_host($host);
            }
        }
    }
    return $hosts;
}

/** Refuse anything but a same-site JSON POST to /apps/<package>/. */
function api_guard(string $package): void
{
    // The one URL the page uses, compared as sent: no parsing, so no "//",
    // "/./" or %-escape can make it name this file from somewhere else.
    $path = explode('?', $_SERVER['REQUEST_URI'] ?? '', 2)[0];
    if ($path !== "/apps/$package/api.php") {
        api_fail(403, "Settings can only be changed through the dashboard (/apps/$package/).");
    }
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        header('Allow: POST');
        api_fail(405, 'Only POST requests are accepted.');
    }
    if (($_SERVER['HTTP_X_SETTINGS_REQUEST'] ?? '') !== '1') {
        api_fail(403, 'The X-Settings-Request header is missing.');
    }
    $source = $_SERVER['HTTP_ORIGIN'] ?? ($_SERVER['HTTP_REFERER'] ?? '');
    if ($source !== '') {
        $source_host = api_url_host($source);
        if ($source_host === null || !in_array($source_host, api_request_hosts(), true)) {
            api_fail(403, 'Requests from other websites are refused.');
        }
    }
}

/** The request body, a JSON object, as an array. */
function api_read_request(): array
{
    if (stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== 0) {
        api_fail(415, 'Send the request as JSON.');
    }
    $body = file_get_contents('php://input', false, null, 0, API_MAX_BODY_BYTES + 1);
    if (!is_string($body) || strlen($body) > API_MAX_BODY_BYTES) {
        api_fail(413, 'The request is too large.');
    }
    $request = json_decode($body, true);
    if (!is_array($request)) {
        api_fail(400, 'The request is not a JSON object.');
    }
    return $request;
}

/** Lines of key=value for ctl.sh's stdin; a list value repeats its key. */
function api_input(array $values): string
{
    $lines = '';
    foreach ($values as $key => $value) {
        foreach (is_array($value) ? $value : [$value] as $item) {
            // Validated values hold no line breaks; this keeps it that way.
            $lines .= $key . '=' . str_replace(["\r", "\n"], '', (string) $item) . "\n";
        }
    }
    return $lines;
}

/** ctl.sh's key=value output lines as [key, value] pairs, in order. */
function api_output_pairs(string $output): array
{
    $pairs = [];
    foreach (explode("\n", $output) as $line) {
        $equals = strpos($line, '=');
        if ($equals !== false) {
            $pairs[] = [substr($line, 0, $equals), substr($line, $equals + 1)];
        }
    }
    return $pairs;
}

/** The value of the first output line with <key>, or null. */
function api_output_value(string $output, string $key): ?string
{
    foreach (api_output_pairs($output) as [$name, $value]) {
        if ($name === $key) {
            return $value;
        }
    }
    return null;
}

/**
 * Run "sh <app>/ctl.sh <command>" with <input> on stdin and return
 * [exit code, stdout]. No shell parses the arguments, the environment holds
 * only PATH, and a command still running after <timeout> seconds is stopped.
 */
function api_run_ctl(string $command, string $input = '', int $timeout = 20): array
{
    // __DIR__ has symlinks resolved: it's the app's own web/ folder.
    $ctl = dirname(__DIR__) . '/ctl.sh';
    $process = proc_open(
        ['/bin/sh', $ctl, $command],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']],
        $pipes,
        '/',
        ['PATH' => API_SEARCH_PATH]
    );
    if (!is_resource($process)) {
        api_fail(500, "Couldn't run the app's ctl.sh.");
    }
    fwrite($pipes[0], $input);
    fclose($pipes[0]);

    $output = '';
    $deadline = microtime(true) + $timeout;
    while (!feof($pipes[1])) {
        $remaining = $deadline - microtime(true);
        if ($remaining <= 0) {
            proc_terminate($process);
            fclose($pipes[1]);
            proc_close($process);
            api_fail(504, "The NAS didn't finish '$command' within {$timeout} seconds.");
        }
        $readable = [$pipes[1]];
        $writable = null;
        $failed = null;
        $seconds = (int) $remaining;
        if (stream_select($readable, $writable, $failed, $seconds, (int) (($remaining - $seconds) * 1e6)) > 0) {
            $output .= (string) fread($pipes[1], 8192);
        }
    }
    fclose($pipes[1]);
    return [proc_close($process), $output];
}
