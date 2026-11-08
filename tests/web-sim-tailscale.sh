# shellcheck shell=sh
# web-sim-tailscale.sh — Tailscale's checks for web-sim.sh, which sources
# this file once the app is installed and ON (a new node, not logged in
# yet), and the web server runs. The helpers and $code and $body (the last
# reply) come from there.
# shellcheck disable=SC2154

section "Tailscale: a new node logs in"
api tailscale '{"action":"status"}'
expect "[ '$code' = 200 ] && [ \"\$(field status.daemon)\" = running ] && [ \"\$(field status.backend_state)\" = NeedsLogin ]" "status: running, needs login"
expect "! echo \"\$body\" | grep -q privkey" "the prefs' private key stays on the NAS"
api tailscale '{"action":"login","auth_key":"not-a-key"}'
expect "[ '$code' = 422 ] && [ \"\$(field fields.auth_key)\" != null ]" "something that isn't a key is refused"
# Test keys are split in two so the public export's check for real keys
# doesn't flag this file.
bad_key="tskey""-auth-stub-bad"
api tailscale "{\"action\":\"login\",\"auth_key\":\"$bad_key\"}"
expect "[ '$code' = 409 ] && field error | grep -q 'refused the key' && ! echo \"\$body\" | grep -qF '$bad_key'" "a key Tailscale rejects: its error, without the key"
expect "[ \"\$(cat '$SOCKET.key-source')\" = /proc/self/fd/0 ]" "the key reached the CLI on stdin, not in a file"
# A node whose login expired: logging it in from the page would make it a
# new device, so the page sends you to "tailscale up".
touch "$SOCKET.node-key"
wait_for "api tailscale '{\"action\":\"status\"}'; [ \"\$(field status.logged_in_before)\" = true ]" 5
api tailscale '{"action":"login","auth_key":""}'
expect "[ '$code' = 409 ] && field error | grep -q 'logged in before'" "a node that was logged in before isn't logged in from the page"
rm -f "$SOCKET.node-key"
wait_for "api tailscale '{\"action\":\"status\"}'; [ \"\$(field status.logged_in_before)\" = false ]" 5
api tailscale '{"action":"login","auth_key":""}'
expect "[ '$code' = 200 ]" "an interactive login starts"
wait_for "api tailscale '{\"action\":\"status\"}'; [ \"\$(field status.auth_url)\" != '' ]" 10
expect "[ \"\$(field status.auth_url)\" = https://login.example/a/stub ]" "status shows the login link"
good_key="tskey""-auth-stub-good"
api tailscale "{\"action\":\"login\",\"auth_key\":\"$good_key\"}"
expect "[ '$code' = 200 ]" "a good key logs the node in"
api tailscale '{"action":"status"}'
expect "[ \"\$(field status.backend_state)\" = Running ] && field status.ips | grep -qx 100.101.102.103" "the node is connected"
expect "! grep -rqF '$good_key' /mnt /var/www /var/run /tmp" "the auth key isn't kept anywhere"
api tailscale '{"action":"login","auth_key":""}'
expect "[ '$code' = 409 ] && field error | grep -q 'already logged in'" "no second login on a connected node"

section "Tailscale: settings"
api tailscale '{"action":"save","hostname":"-bad","routes":["192.168.1.5/24"],"exit_node":false,"auto_update":true}'
expect "[ '$code' = 422 ] && [ \"\$(field fields.hostname)\" != null ] && field fields.routes | grep -q 'Use 192.168.1.0/24'" "a bad name and a route with host bits are refused, with the right range suggested"
api tailscale '{"action":"save","hostname":"","routes":["0.0.0.0/0"],"exit_node":false,"auto_update":true}'
expect "[ '$code' = 422 ] && field fields.routes | grep -q 'exit node'" "a /0 route points to the exit node option"
api tailscale '{"action":"save","hostname":"","routes":[],"exit_node":"yes","auto_update":true}'
expect "[ '$code' = 400 ]" "a non-boolean switch is refused"
api tailscale '{"action":"save","hostname":"nas-test","routes":["192.168.1.0/24","FD00:1::/64"],"exit_node":true,"auto_update":false}'
expect "[ '$code' = 200 ]" "good settings are accepted"
expect "grep -qxF -- '--hostname=nas-test --advertise-routes=192.168.1.0/24,fd00:1::/64 --advertise-exit-node=true --auto-update=false --netfilter-mode=off --snat-subnet-routes=false' '$SOCKET.set-args'" "tailscale set got them, routes written the standard way, with the NAT flags (no iptables here)"
expect "grep -qx net/ipv4/ip_forward '$TS_HOME/ip-forwarding' && grep -qx net/ipv6/conf/all/forwarding '$TS_HOME/ip-forwarding'" "forwarding noted for IPv4, and IPv6 for the IPv6 route"
# The stub daemon rewrites its status once a second.
wait_for "api tailscale '{\"action\":\"status\"}'; [ \"\$(field status.dns_name)\" = nas-test.tailnet.example ]" 5
expect "[ \"\$(field status.prefs.hostname)\" = nas-test ] && [ \"\$(field status.prefs.exit_node)\" = true ] && [ \"\$(field status.prefs.auto_update)\" = false ]" "status shows the new settings"
expect "[ \"\$(field status.prefs.routes | tr '\n' ' ')\" = '192.168.1.0/24 fd00:1::/64 ' ] && [ \"\$(field status.dns_name)\" = nas-test.tailnet.example ]" "routes without the exit node's, and the new name"
expect "[ \"\$(field status.nat)\" = false ]" "status says the kernel has no NAT, for the page's note"
api tailscale '{"action":"save","hostname":"","routes":[],"exit_node":false,"auto_update":true}'
expect "[ '$code' = 200 ] && [ ! -e '$TS_HOME/ip-forwarding' ]" "clearing routes and the exit node drops the forwarding note"

section "Tailscale: disconnect, connect, switch tailnets, log out"
# Refresh $body with the status: called directly, never inside $(...), where
# the reply would stay in the subshell.
ts_status() { api tailscale '{"action":"status"}'; }
ts_state_is() { ts_status; [ "$(field status.backend_state)" = "$1" ]; }
api tailscale '{"action":"save","hostname":"nas-test","routes":[],"exit_node":false,"auto_update":true}'
api tailscale '{"action":"disconnect"}'
expect "[ '$code' = 200 ]" "disconnect is accepted"
wait_for "ts_state_is Stopped" 5
expect "ts_state_is Stopped && [ \"\$(field status.logged_in_before)\" = true ]" "the node is offline, still logged in"
api tailscale '{"action":"connect"}'
expect "[ '$code' = 200 ] && grep -qxF -- '--hostname=nas-test --advertise-routes= --advertise-exit-node=false --netfilter-mode=off --snat-subnet-routes=false --timeout=30s' '$SOCKET.up-args'" "connect runs tailscale up with the node's own settings and the NAT flags, so nothing is reset"
wait_for "ts_state_is Running" 5
expect "ts_state_is Running" "and the node is back"
api tailscale "{\"action\":\"login\",\"auth_key\":\"$bad_key\",\"switch\":true}"
expect "[ '$code' = 409 ] && field error | grep -q 'back on example.com' && grep -qx example.com '$SOCKET.switch-args'" "a switch with a refused key goes straight back to the old tailnet"
wait_for "ts_state_is Running" 5
expect "ts_state_is Running && [ ! -e '$TS_HOME/switched-from' ]" "connected again, with nothing left to go back to"
api tailscale '{"action":"save","hostname":"","routes":["192.168.1.0/24"],"exit_node":false,"auto_update":true}'
api tailscale "{\"action\":\"login\",\"auth_key\":\"$good_key\",\"switch\":true}"
expect "[ '$code' = 200 ] && ts_state_is Running" "a switch with a good key connects to the other tailnet"
expect "ts_status && [ \"\$(field status.switched_from)\" = example.com ] && [ ! -e '$TS_HOME/ip-forwarding' ]" "the old tailnet is remembered, and its routes' forwarding is dropped"
api tailscale '{"action":"login","auth_key":"","switch":true}'
wait_for "ts_status; [ \"\$(field status.auth_url)\" != '' ]" 10
expect "[ \"\$(field status.backend_state)\" = NeedsLogin ] && [ \"\$(field status.switched_from)\" = example.com ]" "an interactive switch waits for its login, with the way back on offer"
api tailscale '{"action":"switch_back"}'
expect "[ '$code' = 200 ]" "going back is accepted"
wait_for "ts_state_is Running" 5
expect "ts_state_is Running && [ \"\$(field status.switched_from)\" = '' ]" "and the NAS is on the old tailnet again"
api tailscale '{"action":"logout"}'
expect "[ '$code' = 200 ]" "log out is accepted"
wait_for "ts_state_is NeedsLogin" 5
expect "ts_state_is NeedsLogin && [ \"\$(field status.logged_in_before)\" = false ]" "logged out: the page can log it in again"
