// settings-common.js — shared by both apps' settings pages: the framing
// check, calls to api.php, form errors, and sizing the dashboard's iframe.
// Each app's build.sh copies it into web/.
"use strict";

const Settings = (() => {
    // These pages belong inside this NAS's own dashboard, or opened on their
    // own. Inside another site's frame they stay blank, so nobody can trick
    // a click on them (clickjacking).
    function framedByOtherSite() {
        try {
            return window.top.location.origin !== window.location.origin;
        } catch (error) {
            return true; // reading a parent from another origin throws
        }
    }

    // The dashboard's iframe doesn't follow its content's height; keep it
    // fitted. The body's height, unlike the document's, can also shrink.
    function fitFrame() {
        const frame = window.frameElement;
        if (frame) {
            frame.style.height = `${Math.ceil(document.body.getBoundingClientRect().height)}px`;
        }
    }

    function start(init) {
        if (framedByOtherSite()) {
            return;
        }
        if (window.top === window) {
            document.documentElement.classList.add("standalone");
        }
        document.getElementById("page").hidden = false;
        new ResizeObserver(fitFrame).observe(document.body);
        init();
    }

    // network: the request never got an answer (as opposed to a refusal).
    function failure(message, network = false) {
        return { ok: false, error: message, fields: {}, network };
    }

    // POST {action, ...data} to api.php; always resolves to {ok, ...}. A
    // request still unanswered after <timeoutMs> counts as no answer: one
    // that cuts the page's own connection (a disconnect over Tailscale) never
    // gets one.
    async function call(action, data = {}, { timeoutMs = 120000 } = {}) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        let response;
        try {
            response = await fetch("api.php", {
                method: "POST",
                credentials: "same-origin",
                headers: { "Content-Type": "application/json", "X-Settings-Request": "1" },
                body: JSON.stringify({ ...data, action }),
                signal: controller.signal,
            });
        } catch (error) {
            return failure("The NAS didn't answer. Check the connection, then reload this page.", true);
        } finally {
            clearTimeout(timer);
        }
        let body = null;
        try {
            body = await response.json();
        } catch (error) {
            // not JSON: handled below
        }
        if (body && typeof body === "object" && typeof body.ok === "boolean") {
            return body;
        }
        if (response.status === 401 || response.status === 403) {
            return failure("Your dashboard login has ended. Log in to the dashboard again, then reopen this page.");
        }
        return failure(`Unexpected reply from the NAS (HTTP ${response.status}).`);
    }

    // Show api.php's per-field messages next to the fields; clear the rest.
    function showFieldErrors(form, fields = {}) {
        for (const slot of form.querySelectorAll("[data-error-for]")) {
            const name = slot.dataset.errorFor;
            slot.textContent = fields[name] || "";
            const input = form.elements.namedItem(name);
            if (input) {
                input.setAttribute("aria-invalid", fields[name] ? "true" : "false");
            }
        }
    }

    function setText(element, text, kind = "") {
        element.textContent = text;
        element.className = `${element.className.split(" ")[0]} ${kind}`.trim();
    }

    function showBanner(element, text, kind = "info") {
        element.hidden = !text;
        setText(element, text || "", kind);
    }

    // The non-empty, trimmed lines of a textarea.
    function lines(text) {
        return text.split("\n").map((line) => line.trim()).filter((line) => line !== "");
    }

    function sleep(milliseconds) {
        return new Promise((resolve) => setTimeout(resolve, milliseconds));
    }

    return { start, call, showFieldErrors, setText, showBanner, lines, sleep };
})();
