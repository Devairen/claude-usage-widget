const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const ACCENT = "#ff8839";
const ACCENT_SOFT = "#ffb27a";
const ACCENT_DEEP = "#ff6a1a";
const WARN = "#ff3b30";

function colorFor(pct) {
  // Start at the punchy accent; gradually deepen as usage climbs; red at danger.
  if (pct < 66) return ACCENT;
  if (pct < 90) return ACCENT_DEEP;
  return WARN;
}

function fmtMinutes(m) {
  if (m == null || !isFinite(m)) return null;
  const total = Math.max(0, Math.floor(m));
  const h = Math.floor(total / 60);
  const min = total % 60;
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  if (h > 0) return `${h}h ${min}m`;
  return `${min}m`;
}

function resetTextFromISO(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (isNaN(d.getTime())) return null;
  const remaining = (d.getTime() - Date.now()) / 60000;
  if (remaining <= 0) return "resetting…";
  const clock = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return `resets in ${fmtMinutes(remaining)} (${clock})`;
}

/* Arc: SVG with a visible track ring underneath, foreground stroke for utilization.
   No label inside — the big number to the right of the arc is the percentage. */
function arcSvg(pct, color) {
  const r = 22;
  const c = 2 * Math.PI * r;
  const visible = pct <= 0 ? 0 : Math.max(pct, 1.5);
  const dash = (Math.min(visible, 100) / 100) * c;
  return `
    <svg viewBox="0 0 52 52" preserveAspectRatio="xMidYMid meet" style="width:100%;height:100%;display:block">
      <circle class="arc-track" cx="26" cy="26" r="${r}"></circle>
      <circle class="arc-fg" cx="26" cy="26" r="${r}"
        stroke="${color}"
        stroke-dasharray="${dash} ${c}"
        stroke-dashoffset="0"></circle>
    </svg>`;
}

/* Session-timeline chart: shows your 5h-session usage curve plus a projection
   line if we have a meaningful burn rate. X-axis is the session window
   (anchored to the reset time), Y-axis is 0–100% utilization.
   Replaces the redundant burn-rate text line. */
function sessionChartSvg({ samples, currentPct, resetISO, burnRate, samplesMinutes }) {
  if (!resetISO) return "";
  const resetMs = new Date(resetISO).getTime();
  if (isNaN(resetMs)) return "";

  const w = 280;
  const h = 64;
  const padT = 4;
  const padB = 14;
  const innerH = h - padT - padB;

  const nowMs = Date.now();
  const sessionMs = 5 * 60 * 60 * 1000;
  const sessionStartMs = resetMs - sessionMs;
  // Range we actually plot: clamp to "from session-start to reset"
  const span = sessionMs;

  const xFor = (ms) => ((ms - sessionStartMs) / span) * w;
  const yFor = (pct) => padT + (1 - Math.max(0, Math.min(100, pct)) / 100) * innerH;

  // Right edge = reset moment, left edge = session start.
  // "Now" line is somewhere between them.
  const xNow = xFor(nowMs);

  // Threshold lines at 50% and 100%
  const y100 = yFor(100);
  const y50 = yFor(50);

  // Real samples (last ~60 min of 5h%). We don't have timestamps in the
  // sparkline payload — just values. Anchor them to "now - N*60s" backwards.
  // If samples arrived once per minute, this is good enough.
  let liveLine = "";
  let liveArea = "";
  if (samples && samples.length >= 2) {
    const minPerSample = 1; // poll cadence is 60s
    const oldestMs = nowMs - (samples.length - 1) * minPerSample * 60 * 1000;
    const pts = samples.map((v, i) => {
      const t = oldestMs + i * minPerSample * 60 * 1000;
      return [xFor(t).toFixed(1), yFor(v).toFixed(1)];
    });
    liveLine = pts.map((p, i) => (i === 0 ? "M" : "L") + p[0] + "," + p[1]).join(" ");
    liveArea =
      liveLine +
      ` L${pts[pts.length - 1][0]},${(h - padB).toFixed(1)}` +
      ` L${pts[0][0]},${(h - padB).toFixed(1)} Z`;
  }

  // Projection line — only meaningful with >=10 min of data
  let projLine = "";
  if (burnRate != null && burnRate > 0 && (samplesMinutes || 0) >= 10) {
    // Project from "now" forward at burnRate %/min until either reset or 100%
    const minsToReset = (resetMs - nowMs) / 60000;
    const minsToCap = Math.min(minsToReset, (100 - currentPct) / burnRate);
    if (minsToCap > 0) {
      const projEndMs = nowMs + minsToCap * 60 * 1000;
      const projEndPct = currentPct + burnRate * minsToCap;
      projLine = `M${xNow.toFixed(1)},${yFor(currentPct).toFixed(1)} L${xFor(projEndMs).toFixed(1)},${yFor(projEndPct).toFixed(1)}`;
    }
  }

  // x-axis labels: session start time and reset time
  const startLbl = new Date(sessionStartMs).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const resetLbl = new Date(resetMs).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const nowLbl = "now";

  // Right-edge x for the reset line
  const xReset = w - 0.5;

  // "now" position as a percentage of the full chart width (for the HTML overlay).
  const nowPct = ((xNow / w) * 100).toFixed(2);

  return `
    <div class="spark">
      <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" class="chart-svg">
        <line class="chart-grid" x1="0" y1="${y50}" x2="${w}" y2="${y50}"/>
        <line class="chart-limit" x1="0" y1="${y100}" x2="${w}" y2="${y100}"/>
        ${liveArea ? `<path class="spark-fill" d="${liveArea}"/>` : ""}
        ${liveLine ? `<path class="spark-line" d="${liveLine}"/>` : ""}
        ${projLine ? `<path class="spark-proj" d="${projLine}"/>` : ""}
        <line class="chart-now" x1="${xNow}" y1="${padT}" x2="${xNow}" y2="${h - padB}"/>
        <line class="chart-reset" x1="${xReset}" y1="${padT}" x2="${xReset}" y2="${h - padB}"/>
      </svg>
      <span class="chart-overlay chart-limit-label">100%</span>
      <span class="chart-overlay chart-x-start">${startLbl}</span>
      <span class="chart-overlay chart-x-now" style="left:${nowPct}%">${nowLbl}</span>
      <span class="chart-overlay chart-x-reset">${resetLbl}</span>
    </div>`;
}

function renderUsageSection({
  title,
  icon,
  percentage,
  resetISO,
  burnRate,
  burnSamplesMin,
  minutesToLimit,
  spark,
  showChart,
}) {
  const pct = percentage || 0;
  const color = colorFor(pct);
  const resetTxt = resetTextFromISO(resetISO);

  // "used up in Xh Ym (HH:MM)" — same shape as the resets line for visual rhythm.
  // Only meaningful with >=10 min of burn samples.
  // If projected use-up time falls AFTER the reset, show "won't hit limit" instead.
  let usedUpTxt = null;
  let usedUpClass = "usage-line-3";
  if (
    burnRate != null &&
    minutesToLimit != null &&
    (burnSamplesMin || 0) >= 10 &&
    resetISO
  ) {
    const resetMs = new Date(resetISO).getTime();
    const usedUpMs = Date.now() + minutesToLimit * 60 * 1000;
    if (!isNaN(resetMs)) {
      if (usedUpMs >= resetMs) {
        usedUpTxt = `won't hit limit at this pace`;
      } else {
        const clock = new Date(usedUpMs).toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        });
        usedUpTxt = `used up in ${fmtMinutes(minutesToLimit)} (${clock})`;
        usedUpClass += " usage-line-warning";
      }
    }
  }

  const chartBlock = showChart
    ? sessionChartSvg({
        samples: spark,
        currentPct: pct,
        resetISO,
        burnRate,
        samplesMinutes: burnSamplesMin,
      })
    : "";

  // data-pct is used by compact mode's CSS ::after to print the % inside the arc
  return `
    <div class="section">
      <div class="section-header">
        <span class="label"><span class="label-icon">${icon}</span>${title}</span>
      </div>
      <div class="usage-row">
        <div class="arc-wrap" data-pct="${pct.toFixed(0)}%">${arcSvg(pct, color)}</div>
        <div class="usage-meta">
          <div class="usage-line-1">${pct.toFixed(1)}%</div>
          ${resetTxt ? `<div class="usage-line-2">${resetTxt}</div>` : ""}
          ${usedUpTxt ? `<div class="${usedUpClass}">${usedUpTxt}</div>` : ""}
        </div>
      </div>
      ${chartBlock}
    </div>`;
}

function renderModels(models) {
  if (!models || !models.length) return "";
  const rows = models
    .map((m) => {
      const color = colorFor(m.percentage || 0);
      return `
      <div class="model-row">
        <div class="model-name">${m.name}</div>
        <div class="model-bar-wrap"><div class="model-bar" style="width:${(m.percentage || 0).toFixed(1)}%;background:${color}"></div></div>
        <div class="model-pct">${(m.percentage || 0).toFixed(1)}%</div>
      </div>`;
    })
    .join("");
  return `
    <div class="section">
      <div class="section-header"><span class="label">Per model</span></div>
      <div class="models">${rows}</div>
    </div>`;
}

function renderExtra(extra) {
  if (!extra || !extra.is_enabled) return "";
  const used = extra.used_credits || 0;
  const limit = extra.monthly_limit || 0;
  const cur = extra.currency || "USD";
  const text = limit > 0
    ? `${used.toFixed(2)} / ${limit.toFixed(2)} ${cur}`
    : `${used.toFixed(2)} ${cur}`;
  return `
    <div class="section">
      <div class="section-header">
        <span class="label"><span class="label-icon">+</span>Extra usage</span>
        <span>${text}</span>
      </div>
    </div>`;
}

// In-memory settings cache, populated on load + when settings change.
let cachedSettings = {
  autostart: true,
  show_models: true,
  show_sparkline: true,
  compact_mode: false,
};

function applyBodyMode() {
  const compact = !!cachedSettings.compact_mode;
  document.body.classList.toggle("compact", compact);
  ensureCompactExpandButton(compact);
}

async function exitCompactMode() {
  cachedSettings.compact_mode = false;
  applyBodyMode();
  await persistSettings({ ...cachedSettings, compact_mode: false });
}

function ensureCompactExpandButton(compact) {
  let btn = document.getElementById("compact-expand");
  if (!compact) {
    if (btn) btn.remove();
    document.body.removeEventListener("contextmenu", compactRightClickHandler);
    document.body.removeEventListener("dblclick", compactDblClickHandler);
    document.body.removeEventListener("mousedown", compactMouseDownHandler);
    return;
  }
  if (!btn) {
    btn = document.createElement("button");
    btn.id = "compact-expand";
    btn.className = "compact-quit";
    btn.title = "Expand (double-click or right-click also work)";
    btn.textContent = "⤢";
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      exitCompactMode();
    });
    document.body.appendChild(btn);
  }
  document.body.addEventListener("contextmenu", compactRightClickHandler);
  document.body.addEventListener("dblclick", compactDblClickHandler);
  document.body.addEventListener("mousedown", compactMouseDownHandler);
}

// JS-driven dragging in compact mode: left-button drag triggers Tauri's
// startDragging(). Lets us keep dblclick / contextmenu firing normally.
async function compactMouseDownHandler(e) {
  if (e.button !== 0) return; // only primary button
  if (e.target.closest("#compact-expand")) return;
  if (e.detail >= 2) return; // ignore the mousedown of a dblclick
  try {
    const { getCurrentWindow } = window.__TAURI__.window;
    await getCurrentWindow().startDragging();
  } catch (err) {
    console.error("startDragging failed:", err);
  }
}

function compactRightClickHandler(e) {
  e.preventDefault();
  exitCompactMode();
}

function compactDblClickHandler(e) {
  // Don't trigger when double-clicking the expand button itself.
  if (e.target.closest("#compact-expand")) return;
  exitCompactMode();
}

function renderLoaded(s) {
  const cookieWarn =
    s.cookie_age_days != null && s.cookie_age_days >= 25
      ? `<div class="warning-banner">Cookie ${s.cookie_age_days} days old — sign in again soon</div>`
      : "";

  return (
    cookieWarn +
    renderUsageSection({
      title: "5h session",
      icon: "◔",
      percentage: s.five_hour_pct,
      resetISO: s.five_hour_resets_at,
      burnRate: s.burn_rate_per_min,
      burnSamplesMin: s.burn_rate_samples_minutes,
      minutesToLimit: s.minutes_to_limit,
      spark: s.spark,
      showChart: cachedSettings.show_sparkline,
    }) +
    renderUsageSection({
      title: "Weekly",
      icon: "▦",
      percentage: s.seven_day_pct,
      resetISO: s.seven_day_resets_at,
    }) +
    (cachedSettings.show_models ? renderModels(s.models) : "") +
    renderExtra(s.extra)
  );
}

function updateFooterAuthAction(state) {
  const btn = document.getElementById("signin-btn");
  if (!btn) return;
  const signedIn = state.kind === "loaded" || state.kind === "authFailed";
  if (signedIn) {
    btn.textContent = "Sign out";
    btn.dataset.action = "sign_out";
  } else {
    btn.textContent = "Sign in";
    btn.dataset.action = "open_auth";
  }
}

function renderState(state) {
  const root = document.getElementById("content");
  const lastUpd = document.getElementById("last-updated");

  applyBodyMode();
  updateFooterAuthAction(state);

  switch (state.kind) {
    case "loading":
      root.innerHTML = `<div class="loading">Loading…</div>`;
      lastUpd.textContent = "";
      break;
    case "needsConfig":
      root.innerHTML = `
        <div class="state-card">
          <div class="icon">◔</div>
          <div class="state-title">Setup required</div>
          <div class="state-body">Sign in to track your Claude usage.</div>
          <button class="btn-primary" id="state-signin">Sign in to Claude</button>
        </div>`;
      lastUpd.textContent = "";
      bind("#state-signin", "click", () => safeInvoke("open_auth"));
      break;
    case "authFailed":
      root.innerHTML = `
        <div class="state-card">
          <div class="icon">⚠</div>
          <div class="state-title">Authentication failed</div>
          <div class="state-body">Your session may have expired.</div>
          <button class="btn-primary" id="state-signin">Sign in again</button>
        </div>`;
      lastUpd.textContent = "";
      bind("#state-signin", "click", () => safeInvoke("open_auth"));
      break;
    case "loaded":
      root.innerHTML = renderLoaded(state);
      // Shorten "13:42:50" to "13:42" — seconds aren't useful at a glance.
      lastUpd.textContent = `Updated ${(state.last_updated || "").slice(0, 5)}`;
      break;
    case "error":
      root.innerHTML = `
        <div class="state-card">
          <div class="icon">✕</div>
          <div class="state-title">Error</div>
          <div class="state-body">${state.message || ""}</div>
        </div>`;
      lastUpd.textContent = "";
      break;
  }
}

function bind(sel, ev, fn) {
  const el = document.querySelector(sel);
  if (el) el.addEventListener(ev, fn);
}

function safeInvoke(cmd) {
  return invoke(cmd).catch((err) => {
    console.error(`invoke("${cmd}") failed:`, err);
    alert(`${cmd} failed: ${err}`);
  });
}

document.getElementById("hide-btn").addEventListener("click", () => safeInvoke("hide_main_window"));
document.getElementById("signin-btn").addEventListener("click", (e) => {
  const action = e.currentTarget.dataset.action || "open_auth";
  safeInvoke(action);
});
document.getElementById("quit-btn").addEventListener("click", () => safeInvoke("hide_main_window"));
document.getElementById("history-btn").addEventListener("click", openHistoryModal);
document.getElementById("settings-btn").addEventListener("click", openSettingsModal);
document.getElementById("modal-close").addEventListener("click", closeModal);
document.getElementById("modal").addEventListener("click", (e) => {
  if (e.target.id === "modal") closeModal();
});

function openModal(title, bodyHTML) {
  document.getElementById("modal-title").textContent = title;
  document.getElementById("modal-body").innerHTML = bodyHTML;
  document.getElementById("modal").classList.remove("hidden");
}

function closeModal() {
  document.getElementById("modal").classList.add("hidden");
  document.getElementById("modal-body").innerHTML = "";
}

/* ---- History modal ---- */

let historyDays = 7;

async function openHistoryModal() {
  openModal("Usage history", historyBody());
  bindHistoryRange();
  await loadHistoryChart();
}

function historyBody() {
  return `
    <div class="history-range">
      ${[1, 7, 30].map((d) =>
        `<button data-days="${d}" class="${d === historyDays ? "active" : ""}">${d === 1 ? "24h" : d + "d"}</button>`
      ).join("")}
    </div>
    <div id="history-chart-host"></div>
    <div class="history-legend">
      <span><span class="swatch" style="background:${ACCENT}"></span>5h session %</span>
      <span><span class="swatch" style="background:${ACCENT_SOFT}; border-top: 1px dashed ${ACCENT_SOFT}"></span>weekly %</span>
    </div>`;
}

function bindHistoryRange() {
  document.querySelectorAll(".history-range button").forEach((b) => {
    b.addEventListener("click", async () => {
      historyDays = parseInt(b.dataset.days, 10);
      document.querySelectorAll(".history-range button").forEach((x) =>
        x.classList.toggle("active", x === b)
      );
      await loadHistoryChart();
    });
  });
}

async function loadHistoryChart() {
  const host = document.getElementById("history-chart-host");
  host.innerHTML = `<div class="history-empty">Loading…</div>`;
  try {
    const points = await invoke("get_history", { days: historyDays });
    if (!points || points.length === 0) {
      host.innerHTML = `<div class="history-empty">No data yet — the widget needs to run for a while.</div>`;
      return;
    }
    host.innerHTML = renderHistoryChart(points);
  } catch (e) {
    console.error(e);
    host.innerHTML = `<div class="history-empty">Couldn't load history: ${e}</div>`;
  }
}

function renderHistoryChart(points) {
  const w = 296;
  const h = 140;
  const padL = 22, padR = 4, padT = 4, padB = 18;
  const innerW = w - padL - padR;
  const innerH = h - padT - padB;

  const tMin = points[0].ts;
  const tMax = points[points.length - 1].ts;
  const tSpan = Math.max(1, tMax - tMin);
  const xFor = (t) => padL + ((t - tMin) / tSpan) * innerW;
  const yFor = (v) => padT + (1 - v / 100) * innerH;

  const path = (key) => {
    let d = "";
    points.forEach((p, i) => {
      const x = xFor(p.ts).toFixed(1);
      const y = yFor(p[key]).toFixed(1);
      d += `${i === 0 ? "M" : "L"}${x},${y} `;
    });
    return d.trim();
  };

  // Y-axis ticks at 0, 50, 100
  const ticks = [0, 50, 100]
    .map((v) => `
      <line class="hc-axis" x1="${padL}" y1="${yFor(v)}" x2="${w - padR}" y2="${yFor(v)}"/>
      <text class="hc-tick" x="${padL - 4}" y="${yFor(v) + 3}" text-anchor="end">${v}</text>
    `).join("");

  // X-axis labels: first, middle, last
  const labelFor = (t) => {
    const d = new Date(t * 1000);
    return historyDays <= 1
      ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      : d.toLocaleDateString([], { month: "short", day: "numeric" });
  };
  const xLabels = `
    <text class="hc-tick" x="${padL}"        y="${h - 4}" text-anchor="start">${labelFor(tMin)}</text>
    <text class="hc-tick" x="${w - padR}"     y="${h - 4}" text-anchor="end">${labelFor(tMax)}</text>
  `;

  return `
    <svg class="history-chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      ${ticks}
      <path class="hc-line-week" d="${path("weekly")}"/>
      <path class="hc-line-five" d="${path("five_hour")}"/>
      ${xLabels}
    </svg>`;
}

/* ---- Settings modal ---- */

async function openSettingsModal() {
  let s = {};
  try {
    s = await invoke("get_settings");
  } catch (e) {
    console.error(e);
  }
  s = {
    autostart: s.autostart ?? true,
    show_models: s.show_models ?? true,
    show_sparkline: s.show_sparkline ?? true,
    notify_enabled: s.notify_enabled ?? true,
    notify_thresholds: s.notify_thresholds ?? [80, 90],
    compact_mode: s.compact_mode ?? false,
  };
  openModal("Settings", settingsBody(s));
  bindSettingsToggles(s);
  bindThresholdEditor(s);
}

function settingsBody(s) {
  const row = (key, label, sub, on) => `
    <div class="settings-row">
      <div>
        <div class="settings-label">${label}</div>
        ${sub ? `<div class="settings-sub">${sub}</div>` : ""}
      </div>
      <div class="toggle ${on ? "on" : ""}" data-key="${key}"></div>
    </div>`;

  const tags = (s.notify_thresholds || [])
    .slice()
    .sort((a, b) => a - b)
    .map((t) => `<span class="threshold-tag" data-t="${t}">${t}% <span class="x">×</span></span>`)
    .join("");

  const thresholdRow = `
    <div class="settings-row settings-thresholds">
      <div style="flex:1; min-width:0">
        <div class="settings-label">Notification thresholds</div>
        <div class="settings-sub">Fire when 5h session crosses each level.</div>
        <div class="threshold-tags">
          ${tags || `<span class="settings-sub">none</span>`}
          <button class="threshold-add" id="threshold-add-btn">+ add</button>
        </div>
      </div>
    </div>`;

  return (
    row("autostart", "Start with Windows", "Run silently in the tray on login.", s.autostart) +
    row("compact_mode", "Compact widget", "Tiny always-on-top window — ring + % + reset only.", s.compact_mode) +
    row("notify_enabled", "Notifications", "Toast when usage crosses a threshold.", s.notify_enabled) +
    thresholdRow +
    row("show_models", "Show per-model breakdown", "Sonnet / Opus / Design rows.", s.show_models) +
    row("show_sparkline", "Show 5h trend chart", "", s.show_sparkline)
  );
}

async function persistSettings(s) {
  try {
    await invoke("set_settings", { settings: s });
    cachedSettings = { ...cachedSettings, ...s };
    const cur = await invoke("get_state");
    renderState(cur);
  } catch (e) {
    console.error(e);
    alert(`Failed to save settings: ${e}`);
    return false;
  }
  return true;
}

function bindSettingsToggles(s) {
  document.querySelectorAll(".toggle[data-key]").forEach((el) => {
    el.addEventListener("click", async () => {
      const key = el.dataset.key;
      const prev = s[key];
      s[key] = !s[key];
      el.classList.toggle("on", s[key]);
      const ok = await persistSettings(s);
      if (!ok) {
        s[key] = prev;
        el.classList.toggle("on", s[key]);
      }
    });
  });
}

function bindThresholdEditor(s) {
  const refresh = () => {
    // Re-render the modal body to reflect threshold list changes.
    document.getElementById("modal-body").innerHTML = settingsBody(s);
    bindSettingsToggles(s);
    bindThresholdEditor(s);
  };

  document.querySelectorAll(".threshold-tag").forEach((el) => {
    el.addEventListener("click", async () => {
      const t = parseFloat(el.dataset.t);
      s.notify_thresholds = (s.notify_thresholds || []).filter((x) => x !== t);
      await persistSettings(s);
      refresh();
    });
  });

  const addBtn = document.getElementById("threshold-add-btn");
  if (addBtn) {
    addBtn.addEventListener("click", async () => {
      const v = prompt("Threshold % (1–99):");
      if (v == null) return;
      const n = parseFloat(v);
      if (!isFinite(n) || n < 1 || n > 99) {
        alert("Enter a number between 1 and 99.");
        return;
      }
      const set = new Set(s.notify_thresholds || []);
      set.add(Math.round(n));
      s.notify_thresholds = Array.from(set).sort((a, b) => a - b);
      await persistSettings(s);
      refresh();
    });
  }
}

(async () => {
  try {
    const s = await invoke("get_settings");
    cachedSettings = {
      autostart: s.autostart ?? true,
      show_models: s.show_models ?? true,
      show_sparkline: s.show_sparkline ?? true,
      compact_mode: s.compact_mode ?? false,
    };
  } catch (e) {
    console.error("get_settings failed", e);
  }
  applyBodyMode();
  try {
    const initial = await invoke("get_state");
    renderState(initial);
  } catch (e) {
    console.error(e);
  }
})();

listen("state-updated", (event) => {
  renderState(event.payload);
});

listen("config-updated", () => {});
