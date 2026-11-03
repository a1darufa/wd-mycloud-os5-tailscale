<?php
// web-client.php — helpers for tests/web-sim.sh, whose image has no curl or
// jq:
//   request <method> <path> <body> [header ...]
//       send it to the test server; print the HTTP status, then the body
//   field <json> <key.key...>
//       print one value: a list one item per line, true/false as words,
//       missing as "null"

declare(strict_types=1);

const SERVER = 'http://127.0.0.1:8080';

function request(string $method, string $path, string $body, array $headers): void
{
    $context = stream_context_create(['http' => [
        'method' => $method,
        'header' => implode("\r\n", $headers),
        'content' => $body,
        'ignore_errors' => true,
        'timeout' => 120,
    ]]);
    $response = file_get_contents(SERVER . $path, false, $context);
    $status = '000';
    if (isset($http_response_header[0]) && preg_match('~^HTTP/\S+ (\d{3})~', $http_response_header[0], $match)) {
        $status = $match[1];
    }
    echo $status, "\n", $response === false ? '' : $response, "\n";
}

function field(string $json, string $path): void
{
    $value = json_decode($json, true);
    foreach (explode('.', $path) as $key) {
        $value = is_array($value) && array_key_exists($key, $value) ? $value[$key] : null;
    }
    if (is_bool($value)) {
        echo $value ? 'true' : 'false', "\n";
    } elseif ($value === null) {
        echo "null\n";
    } elseif (is_array($value)) {
        foreach ($value as $item) {
            echo is_scalar($item) ? (string) $item : json_encode($item), "\n";
        }
    } else {
        echo $value, "\n";
    }
}

switch ($argv[1] ?? '') {
    case 'request':
        request($argv[2], $argv[3], $argv[4] ?? '', array_slice($argv, 5));
        break;
    case 'field':
        field($argv[2] ?? '', $argv[3] ?? '');
        break;
    default:
        fwrite(STDERR, "usage: web-client.php request|field ...\n");
        exit(2);
}
