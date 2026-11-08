// settings.js — Tailscale's settings page: shows the node's state, logs it
// in (login link or auth key), saves a few settings, and can disconnect,
// log out or switch tailnets, all through api.php. Those last three ask
// twice: on a remote NAS, Tailscale may be the only way back in.
"use strict";

(() => {
    const POLL_INTERVAL_MS = 2000;
    const LOGIN_TIMEOUT_MS = 10 * 60 * 1000;
    // Long enough for a normal answer; a disconnect through Tailscale never
    // gets one, since it cuts the connection the answer would come back on.
    const CUTTING_TIMEOUT_MS = 20000;

    const $ = (id) => document.getElementById(id);
    const page = {
        state: $("state"),
        banner: $("banner"),
        node: $("node"),
        nodeName: $("node-name"),
        nodeIps: $("node-ips"),
        nodeTailnet: $("node-tailnet"),
        nodeVersion: $("node-version"),
        health: $("health"),
        login: $("login"),
        loginTitle: $("login-title"),
        loginIntro: $("login-intro"),
        switchIntro: $("switch-intro"),
        switchKeyOnly: $("switch-key-only"),
        switchBackRow: $("switch-back-row"),
        switchBack: $("switch-back"),
        switchBackStatus: $("switch-back-status"),
        loginAccount: $("login-account"),
        loginStart: $("login-start"),
        loginLink: $("login-link"),
        loginStatus: $("login-status"),
        keyForm: $("key-form"),
        keySubmit: $("key-submit"),
        keyStatus: $("key-status"),
        switchCancel: $("switch-cancel"),
        settings: $("settings"),
        noNat: $("no-nat"),
        save: $("save"),
        saveStatus: $("save-status"),
        leave: $("leave"),
        viaTailscale: $("via-tailscale"),
        leaveOk: $("leave-ok"),
        disconnect: $("disconnect"),
        connect: $("connect"),
        logout: $("logout"),
        switchButton: $("switch"),
        leaveStatus: $("leave-status"),
    };
    let lastStatus = null;
    let loginPolling = false;
    // "Connect to another tailnet" was chosen: the login card is shown for it.
    let switching = false;

    const BACKEND_STATES = {
        Running: ["Connected", "ok"],
        NeedsLogin: ["Needs login", "warn"],
        NeedsMachineAuth: ["Waiting for approval", "warn"],
        Starting: ["Connecting...", "warn"],
        Stopped: ["Disconnected", "warn"],
        NoState: ["Starting...", "warn"],
    };

    // Was this page opened through Tailscale (the node's own address or
    // name, or any tailnet address)? Then cutting the connection cuts it too.
    function openedThroughTailscale(status) {
        const host = location.hostname.replace(/^\[|\]$/g, "").toLowerCase();
        const name = status.dns_name.toLowerCase();
        const domain = name.indexOf(".") > 0 ? name.slice(name.indexOf(".")) : "";
        if (status.ips.includes(host) || (name && host === name) || (domain && host.endsWith(domain))) {
            return true;
        }
        const ipv4 = host.match(/^100\.(\d+)\.\d+\.\d+$/);
        if (ipv4 && Number(ipv4[1]) >= 64 && Number(ipv4[1]) <= 127) {
            return true; // 100.64.0.0/10, Tailscale's IPv4 range
        }
        return host.startsWith("fd7a:115c:a1e0:"); // Tailscale's IPv6 range
    }

    // [badge text, badge kind]
    function describeState(status) {
        switch (status.daemon) {
            case "running":
                return BACKEND_STATES[status.backend_state] || [status.backend_state || "Starting...", "warn"];
            case "foreign":
                return ["Another Tailscale is running", "warn"];
            default:
                if (status.first_start === "pending" && status.should_run) {
                    return ["Starting...", "warn"];
                }
                return status.should_run ? ["Not running", "error"] : ["Switched off", ""];
        }
    }

    // [banner text or "", banner kind]
    function describeProblem(status) {
        if (status.first_start === "failed") {
            return [`The first start didn't take over the existing Tailscale: ${status.first_start_message} `
                + "The earlier setup was left running. See the log, fix the cause, then install the app again to retry.", "error"];
        }
        if (status.daemon === "foreign") {
            return ["A Tailscale that this app didn't start is running (for example from Entware or another "
                + "folder). Stop it first; this app won't run a second one next to it.", "warn"];
        }
        if (status.daemon === "running" && status.backend_state === "NeedsLogin" && status.logged_in_before) {
            return ["This NAS was logged in before: its login expired, or it was removed from the tailnet. "
                + "Log it in again over SSH with \"tailscale up\", which keeps its identity and address. "
                + "Connecting to a tailnet from this page makes it a new device.", "warn"];
        }
        if (status.daemon === "running" && status.backend_state === "NeedsMachineAuth") {
            return ["This NAS is logged in and waits for approval: approve it in the Tailscale admin console "
                + "under Machines.", "warn"];
        }
        if (status.daemon === "stopped" && status.should_run && status.first_start !== "pending") {
            return ["Tailscale should be running but isn't. See the log in /mnt/HD/HD_a2/.systemfile/tailscale/log.", "error"];
        }
        return ["", ""];
    }

    function renderNode(status) {
        const known = status.daemon === "running" && status.ips.length > 0;
        page.node.hidden = !known;
        if (!known) {
            return;
        }
        page.nodeName.textContent = status.dns_name || status.host_name || "-";
        page.nodeIps.textContent = status.ips.join(", ");
        page.nodeTailnet.textContent = status.tailnet || "-";
        page.nodeVersion.textContent = status.version || "-";
        page.health.replaceChildren(...status.health.map((message) => {
            const item = document.createElement("li");
            item.textContent = message;
            return item;
        }));
    }

    function renderLogin(status) {
        const running = status.daemon === "running";
        const fresh = running && status.backend_state === "NeedsLogin" && !status.logged_in_before;
        page.login.hidden = !(fresh || (running && switching));
        if (page.login.hidden) {
            return;
        }
        // While still on a tailnet, a switch can only use a key if the page
        // runs through Tailscale (see #switch-key-only).
        const stillOnTailnet = status.backend_state !== "NeedsLogin";
        const keyOnly = switching && stillOnTailnet && openedThroughTailscale(status);
        page.loginTitle.textContent = switching ? "Connect to another tailnet" : "Join your tailnet";
        page.loginIntro.hidden = switching;
        page.switchIntro.hidden = !switching;
        page.switchKeyOnly.hidden = !keyOnly;
        page.loginAccount.hidden = keyOnly;
        page.switchCancel.hidden = !switching;
        page.keySubmit.textContent = switching ? "Switch with this key" : "Join with this key";

        page.loginLink.hidden = !status.auth_url;
        if (status.auth_url) {
            page.loginLink.href = status.auth_url;
            Settings.setText(page.loginStatus, "Log in there; this page updates once the NAS is connected.");
        }
        // Waiting for a login after a switch: offer the way back.
        page.switchBackRow.hidden = !(status.switched_from && status.backend_state === "NeedsLogin");
        page.switchBack.textContent = `Go back to ${status.switched_from}`;
    }

    function renderLeave(status) {
        const state = status.backend_state;
        const shown = status.daemon === "running" && !switching
            && (state !== "NeedsLogin" || status.logged_in_before);
        page.leave.hidden = !shown;
        if (!shown) {
            return;
        }
        page.viaTailscale.hidden = !openedThroughTailscale(status) || state === "Stopped";
        page.disconnect.hidden = !(state === "Running" || state === "Starting");
        page.connect.hidden = state !== "Stopped";
        page.logout.hidden = state === "NeedsLogin";
        const confirmed = page.leaveOk.checked;
        page.disconnect.disabled = !confirmed;
        page.logout.disabled = !confirmed;
        page.switchButton.disabled = !confirmed;
    }

    function render(status) {
        lastStatus = status;
        Settings.setText(page.state, ...describeState(status));
        Settings.showBanner(page.banner, ...describeProblem(status));
        renderNode(status);
        renderLogin(status);
        renderLeave(status);
        page.settings.hidden = switching
            || !(status.daemon === "running" && status.backend_state === "Running" && status.prefs);
        page.noNat.hidden = status.nat;
    }

    function fillSettings(prefs) {
        const fields = page.settings.elements;
        fields.hostname.value = prefs.hostname;
        fields.routes.value = prefs.routes.join("\n");
        fields.exit_node.checked = prefs.exit_node;
        fields.auto_update.checked = prefs.auto_update;
    }

    async function loadStatus() {
        const reply = await Settings.call("status");
        if (!reply.ok) {
            Settings.setText(page.state, "Unknown", "error");
            Settings.showBanner(page.banner, reply.error, "error");
            return null;
        }
        render(reply.status);
        return reply.status;
    }

    async function reloadAll() {
        const status = await loadStatus();
        if (status && status.prefs) {
            fillSettings(status.prefs);
        }
        return status;
    }

    // After a login starts, follow the state until the node is connected.
    async function followLogin() {
        if (loginPolling) {
            return;
        }
        loginPolling = true;
        const deadline = Date.now() + LOGIN_TIMEOUT_MS;
        while (Date.now() < deadline) {
            await Settings.sleep(POLL_INTERVAL_MS);
            const status = await loadStatus();
            if (status && status.backend_state === "Running") {
                switching = false;
                render(status);
                if (status.prefs) {
                    fillSettings(status.prefs);
                }
                break;
            }
        }
        loginPolling = false;
    }

    async function startLogin() {
        page.loginStart.disabled = true;
        Settings.setText(page.loginStatus, "Asking Tailscale for a login link...");
        const reply = await Settings.call("login", { auth_key: "", switch: switching });
        page.loginStart.disabled = false;
        if (!reply.ok) {
            Settings.setText(page.loginStatus, reply.error, "error");
            return;
        }
        followLogin();
    }

    async function loginWithKey(event) {
        event.preventDefault();
        const field = page.keyForm.elements.auth_key;
        Settings.showFieldErrors(page.keyForm);
        if (field.value.trim() === "") {
            Settings.showFieldErrors(page.keyForm, { auth_key: "Paste an auth key first." });
            return;
        }
        if (switching && !window.confirm("Switch this NAS to the tailnet of this key? It leaves the current "
            + "tailnet at once and joins the other one as a new device.")) {
            return;
        }
        const leavingThisPage = switching && openedThroughTailscale(lastStatus);
        page.keySubmit.disabled = true;
        Settings.setText(page.keyStatus, "Logging in; this can take up to a minute...");
        const reply = await Settings.call("login", { auth_key: field.value.trim(), switch: switching },
            leavingThisPage ? { timeoutMs: 60000 } : {});
        page.keySubmit.disabled = false;
        if (!reply.ok && reply.network && leavingThisPage) {
            field.value = "";
            Settings.setText(page.keyStatus, "The NAS has most likely switched: this page ran through the old "
                + "tailnet. Open the dashboard through the NAS's address on the new tailnet.", "ok");
            return;
        }
        if (!reply.ok) {
            Settings.showFieldErrors(page.keyForm, reply.fields);
            Settings.setText(page.keyStatus, reply.error, "error");
            await loadStatus();
            return;
        }
        field.value = "";
        switching = false;
        Settings.setText(page.keyStatus, "Logged in.", "ok");
        await reloadAll();
    }

    async function save(event) {
        event.preventDefault();
        const fields = page.settings.elements;
        Settings.showFieldErrors(page.settings);
        page.save.disabled = true;
        Settings.setText(page.saveStatus, "Saving...");
        const reply = await Settings.call("save", {
            hostname: fields.hostname.value.trim(),
            routes: Settings.lines(fields.routes.value),
            exit_node: fields.exit_node.checked,
            auto_update: fields.auto_update.checked,
        });
        page.save.disabled = false;
        if (!reply.ok) {
            Settings.showFieldErrors(page.settings, reply.fields);
            Settings.setText(page.saveStatus, reply.error, "error");
            return;
        }
        Settings.setText(page.saveStatus, "Saved.", "ok");
        await reloadAll();
    }

    // Disconnect or log out, after a confirmation that says what happens.
    async function cutConnection(action, question, doneText) {
        const throughTailscale = openedThroughTailscale(lastStatus);
        const warning = throughTailscale
            ? "\n\nYou opened this page through Tailscale: it stops answering at once."
            : "";
        if (!window.confirm(question + warning)) {
            return;
        }
        Settings.setText(page.leaveStatus, "Working...");
        const reply = await Settings.call(action, {}, { timeoutMs: CUTTING_TIMEOUT_MS });
        page.leaveOk.checked = false;
        if (!reply.ok && reply.network && throughTailscale) {
            Settings.setText(page.leaveStatus, `${doneText} This page ran through Tailscale and can't reach `
                + "the NAS any more; open the dashboard through its local address.", "ok");
            return;
        }
        if (!reply.ok) {
            Settings.setText(page.leaveStatus, reply.error, "error");
        } else {
            Settings.setText(page.leaveStatus, doneText, "ok");
        }
        await reloadAll();
    }

    function disconnect() {
        cutConnection("disconnect",
            "Disconnect this NAS from your tailnet? It stays logged in, and Connect on this page brings it back "
            + "(reach the page through the NAS's local address).",
            "Disconnected.");
    }

    function logout() {
        cutConnection("logout",
            "Log this NAS out of your tailnet? To come back it has to log in again, and it then joins as a new "
            + "device with a new address.",
            "Logged out.");
    }

    async function connect() {
        page.connect.disabled = true;
        Settings.setText(page.leaveStatus, "Connecting...");
        const reply = await Settings.call("connect");
        page.connect.disabled = false;
        Settings.setText(page.leaveStatus, reply.ok ? "Connected." : reply.error, reply.ok ? "ok" : "error");
        await reloadAll();
    }

    function startSwitch() {
        if (!window.confirm("Connect this NAS to another tailnet? You'll log in to the other tailnet next; "
            + "the NAS leaves this one when that login starts.")) {
            return;
        }
        switching = true;
        page.leaveOk.checked = false;
        render(lastStatus);
        page.login.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    function cancelSwitch() {
        switching = false;
        Settings.showFieldErrors(page.keyForm);
        Settings.setText(page.keyStatus, "");
        render(lastStatus);
    }

    async function switchBack() {
        page.switchBack.disabled = true;
        Settings.setText(page.switchBackStatus, "Switching back...");
        const reply = await Settings.call("switch_back");
        page.switchBack.disabled = false;
        if (!reply.ok) {
            Settings.setText(page.switchBackStatus, reply.error, "error");
            return;
        }
        switching = false;
        Settings.setText(page.switchBackStatus, "");
        await reloadAll();
    }

    Settings.start(async () => {
        page.loginStart.addEventListener("click", startLogin);
        page.keyForm.addEventListener("submit", loginWithKey);
        page.settings.addEventListener("submit", save);
        page.leaveOk.addEventListener("change", () => renderLeave(lastStatus));
        page.disconnect.addEventListener("click", disconnect);
        page.connect.addEventListener("click", connect);
        page.logout.addEventListener("click", logout);
        page.switchButton.addEventListener("click", startSwitch);
        page.switchCancel.addEventListener("click", cancelSwitch);
        page.switchBack.addEventListener("click", switchBack);
        const status = await reloadAll();
        // A login started earlier (or in another tab) is still waiting.
        if (status && (status.auth_url || status.first_start === "pending")) {
            followLogin();
        }
    });
})();
