<?php
// api.php — the server side of Tailscale's settings page. It reads the
// daemon's state and hands checked changes to ctl.sh; app-api.php explains
// how requests are guarded. Actions (JSON POST): "status", "login", "save",
// "disconnect", "connect", "logout", "switch_back".

declare(strict_types=1);

require __DIR__ . '/app-api.php';

const TS_MAX_ROUTES = 16;
// Advertising these is what "offer as an exit node" means.
const TS_EXIT_ROUTES = ['0.0.0.0/0', '::/0'];

api_guard('tailscale');
$request = api_read_request();

switch ($request['action'] ?? '') {
    case 'status':
        api_reply(['ok' => true, 'status' => tailscale_status()]);
        break;
    case 'login':
        tailscale_login($request);
        break;
    case 'save':
        tailscale_save($request);
        break;
    case 'connect':
        tailscale_connect();
        break;
    case 'disconnect':
        tailscale_simple_command('web-disconnect');
        break;
    case 'logout':
        tailscale_simple_command('web-logout');
        break;
    case 'switch_back':
        tailscale_simple_command('web-switch-back');
        break;
    default:
        api_fail(400, 'Unknown action.');
}

function ts_text($value): string
{
    return is_string($value) ? $value : '';
}

function ts_texts($value): array
{
    return is_array($value) ? array_values(array_filter($value, 'is_string')) : [];
}

function ts_array($value): array
{
    return is_array($value) ? $value : [];
}

/**
 * What the page shows, picked field by field from the daemon's status and
 * prefs; everything else (keys, peers, profiles) stays on the NAS.
 */
function tailscale_status(): array
{
    [$code, $output] = api_run_ctl('web-status');
    $raw = json_decode($output, true);
    if ($code !== 0 || !is_array($raw)) {
        api_fail(500, "Couldn't read Tailscale's state on the NAS.");
    }
    $app = ts_array($raw['app'] ?? null);
    $status = ts_array($raw['status'] ?? null);
    $prefs = ts_array($raw['prefs'] ?? null);
    $self = ts_array($status['Self'] ?? null);

    // Only an https link is shown as the login link.
    $auth_url = ts_text($status['AuthURL'] ?? null);
    if (strpos($auth_url, 'https://') !== 0) {
        $auth_url = '';
    }

    $advertised = ts_texts($prefs['AdvertiseRoutes'] ?? null);
    return [
        'daemon' => ts_text($app['daemon'] ?? null),
        'should_run' => ($app['should_run'] ?? false) === true,
        'first_start' => ts_text($app['first_start'] ?? null),
        'first_start_message' => ts_text($app['first_start_message'] ?? null),
        // The tailnet the last switch left, which the page can return to.
        'switched_from' => ts_text($app['switched_from'] ?? null),
        'backend_state' => ts_text($status['BackendState'] ?? null),
        // A node that needs a login but has a node key was logged in before;
        // ctl.sh only logs in nodes that never were.
        'logged_in_before' => ($status['HaveNodeKey'] ?? null) === true,
        'auth_url' => $auth_url,
        'version' => ts_text($status['Version'] ?? null),
        'tailnet' => ts_text(ts_array($status['CurrentTailnet'] ?? null)['Name'] ?? null),
        'dns_name' => rtrim(ts_text($self['DNSName'] ?? null), '.'),
        'host_name' => ts_text($self['HostName'] ?? null),
        'ips' => ts_texts($self['TailscaleIPs'] ?? ($status['TailscaleIPs'] ?? null)),
        'health' => ts_texts($status['Health'] ?? null),
        'prefs' => $prefs === [] ? null : [
            'hostname' => ts_text($prefs['Hostname'] ?? null),
            'routes' => array_values(array_diff($advertised, TS_EXIT_ROUTES)),
            'exit_node' => array_intersect($advertised, TS_EXIT_ROUTES) !== [],
            'auto_update' => (ts_array($prefs['AutoUpdate'] ?? null)['Apply'] ?? null) === true,
        ],
    ];
}

function tailscale_login(array $request): void
{
    $key = $request['auth_key'] ?? '';
    $key = is_string($key) ? trim($key) : '';
    // An auth key from the admin console; OAuth client secrets may carry
    // ?options. Empty means an interactive login with a link.
    if ($key !== '' && !preg_match('/^tskey-[A-Za-z0-9][A-Za-z0-9_-]{8,250}(\?[A-Za-z0-9=&_.-]{0,200})?$/', $key)) {
        api_fail(422, 'Check the auth key.', ['auth_key' => "That doesn't look like an auth key from the Tailscale admin console."]);
    }
    // switch: move a logged-in node to another tailnet (a new profile).
    $switch = ($request['switch'] ?? false) === true;
    // A login with a key waits up to 45 seconds for the node to connect.
    [$code, $output] = api_run_ctl('web-login', api_input(['auth_key' => $key, 'switch' => $switch ? '1' : '0']), 60);
    if ($code !== 0) {
        api_fail(409, api_output_value($output, 'error') ?? "The NAS didn't accept the login.");
    }
    api_reply(['ok' => true]);
}

/** Run a ctl.sh command that takes no input; reply with its result. */
function tailscale_simple_command(string $command): void
{
    [$code, $output] = api_run_ctl($command, '', 30);
    if ($code !== 0) {
        api_fail(409, api_output_value($output, 'error') ?? "The NAS didn't do it.");
    }
    api_reply(['ok' => true]);
}

/**
 * "tailscale up" again after a disconnect. It resets every setting it isn't
 * given, so it gets the node's current ones, read back from the daemon.
 */
function tailscale_connect(): void
{
    $prefs = tailscale_status()['prefs'];
    if ($prefs === null) {
        api_fail(409, "Couldn't read the current settings; connect over SSH with \"tailscale up\".");
    }
    $routes = [];
    foreach ($prefs['routes'] as $route) {
        $checked = tailscale_route($route);
        if (isset($checked['route'])) {
            $routes[] = $checked['route'];
        }
    }
    [$code, $output] = api_run_ctl('web-connect', api_input([
        'hostname' => $prefs['hostname'],
        'routes' => implode(',', $routes),
        'exit_node' => $prefs['exit_node'] ? 'true' : 'false',
    ]), 45);
    if ($code !== 0) {
        api_fail(409, api_output_value($output, 'error') ?? "The NAS didn't reconnect.");
    }
    api_reply(['ok' => true]);
}

/**
 * ["route" => <route> written the standard way] ("192.168.1.0/24",
 * "fd00::/8"), or ["error" => why not]. Host bits must be zero, as Tailscale requires.
 */
function tailscale_route(string $route): array
{
    $problem = "\"$route\" isn't an address range such as 192.168.1.0/24.";
    if (!preg_match('~^([0-9A-Fa-f:.]+)/([0-9]{1,3})$~', $route, $parts)
        || filter_var($parts[1], FILTER_VALIDATE_IP) === false) {
        return ['error' => $problem];
    }
    $address = (string) inet_pton($parts[1]);
    $length = (int) $parts[2];
    if ($length === 0) {
        return ['error' => 'For all internet traffic, use "Offer this NAS as an exit node" instead of a /0 route.'];
    }
    if ($length > strlen($address) * 8) {
        return ['error' => $problem];
    }
    $network = '';
    for ($byte = 0; $byte < strlen($address); $byte++) {
        $kept_bits = max(0, min(8, $length - $byte * 8));
        $network .= chr(ord($address[$byte]) & ((0xFF << (8 - $kept_bits)) & 0xFF));
    }
    $canonical = inet_ntop($network) . '/' . $length;
    if ($network !== $address) {
        return ['error' => "Use $canonical (the range's first address) instead of $route."];
    }
    return ['route' => $canonical];
}

function tailscale_save(array $request): void
{
    $errors = [];

    $hostname = is_string($request['hostname'] ?? null) ? trim($request['hostname']) : '';
    if ($hostname !== '' && !preg_match('/^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/', $hostname)) {
        $errors['hostname'] = 'Use letters, digits and dashes (not first or last), up to 63; or leave it empty.';
    }

    $routes = [];
    foreach (ts_array($request['routes'] ?? null) as $route) {
        $checked = tailscale_route(is_string($route) ? trim($route) : '');
        if (isset($checked['error'])) {
            $errors['routes'] = $checked['error'];
            break;
        }
        $routes[] = $checked['route'];
    }
    if (count($routes) > TS_MAX_ROUTES) {
        $errors['routes'] = 'Offer at most ' . TS_MAX_ROUTES . ' routes.';
    }

    $exit_node = $request['exit_node'] ?? null;
    $auto_update = $request['auto_update'] ?? null;
    if (!is_bool($exit_node) || !is_bool($auto_update)) {
        api_fail(400, 'exit_node and auto_update must be true or false.');
    }
    if ($errors !== []) {
        api_fail(422, 'Some values need fixing.', $errors);
    }

    [$code, $output] = api_run_ctl('web-set', api_input([
        'hostname' => $hostname,
        'routes' => implode(',', array_unique($routes)),
        'exit_node' => $exit_node ? 'true' : 'false',
        'auto_update' => $auto_update ? 'true' : 'false',
    ]), 30);
    if ($code !== 0) {
        api_fail(409, api_output_value($output, 'error') ?? "The NAS didn't accept the settings.");
    }
    api_reply(['ok' => true]);
}
