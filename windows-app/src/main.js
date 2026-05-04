const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const TAN = "#e89b68";
const ORANGE = "#e06b3e";
const DEEP = "#cc4822";
const RED = "#c0281c";

function colorFor(pct) {
  if (pct < 33) return TAN;
  if (pct < 66) return ORANGE;
  if (pct < 90) return DEEP;
  return RED;
}

function fmtMinutes(m) {
  if (m == null || !isFinite(m)) return null;
  const total = Math.floor(m);
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

function arcSvg(pct, color) {
  const r = 18;
  const c = 2 * Math.PI * r;
  const dash = (Math.min(Math.max(pct, 0), 100) / 100) * c;
  return `
    <svg viewBox="0 0 44 44">
      <circle class="arc-track" cx="22" cy="22" r="${r}"></circle>
      <circle class="arc-fg" cx="22" cy="22" r="${r}"
        stroke="${color}"
        stroke-dasharray="${dash} ${c}"
        stroke-dashoffset="0"></circle>
    </svg>`;
}

function renderUsageSection({ title, icon, percentage, resetISO, burnRate, minutesToLimit, willHitLimit }) {
  const pct = percentage || 0;
  const color = colorFor(pct);
  const resetTxt = resetTextFromISO(resetISO);

  let line2 = resetTxt || "";
  let line2Class = "usage-line-2";
  if (burnRate != null && minutesToLimit != null) {
    const limitTxt = `limit in ~${fmtMinutes(minutesToLimit)} · ${burnRate.toFixed(1)}%/min`;
    line2 = willHitLimit ? limitTxt : (resetTxt || limitTxt);
    if (willHitLimit) line2Class += " usage-line-warning";
  }

  return `
    <div class="section">
      <div class="section-header"><span><span class="section-icon">${icon}</span>${title}</span></div>
      <div class="usage-row">
        <div class="arc-wrap">${arcSvg(pct, color)}<div class="arc-label">${pct.toFixed(0)}%</div></div>
        <div class="usage-meta">
          <div class="usage-line-1">${pct.toFixed(1)}% used</div>
          <div class="${line2Class}">${line2 || ""}</div>
        </div>
      </div>
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
  return `<div class="models">${rows}</div>`;
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
      <div class="section-header"><span><span class="section-icon">💳</span>Extra usage</span><span>${text}</span></div>
    </div>`;
}

function renderLoaded(s) {
  const cookieWarn = s.cookie_age_days != null && s.cookie_age_days >= 25
    ? `<div class="warning-banner">Cookie ${s.cookie_age_days} days old — sign in again soon</div>`
    : "";

  return (
    cookieWarn +
    renderUsageSection({
      title: "5h session",
      icon: "⏱",
      percentage: s.five_hour_pct,
      resetISO: s.five_hour_resets_at,
      burnRate: s.burn_rate_per_min,
      minutesToLimit: s.minutes_to_limit,
      willHitLimit: s.will_hit_limit,
    }) +
    renderUsageSection({
      title: "Weekly (7d)",
      icon: "📅",
      percentage: s.seven_day_pct,
      resetISO: s.seven_day_resets_at,
    }) +
    (s.models && s.models.length
      ? `<div class="section"><div class="section-header"><span>Per model</span></div>${renderModels(s.models)}</div>`
      : "") +
    renderExtra(s.extra)
  );
}

function renderState(state) {
  const root = document.getElementById("content");
  const lastUpd = document.getElementById("last-updated");

  switch (state.kind) {
    case "loading":
      root.innerHTML = `<div class="loading">Loading…</div>`;
      lastUpd.textContent = "";
      break;
    case "needsConfig":
      root.innerHTML = `
        <div class="state-card">
          <div class="icon">🔑</div>
          <div class="state-title">Setup required</div>
          <div class="state-body">Sign in to start tracking your Claude usage.</div>
          <button class="btn-primary" id="state-signin">Sign in to Claude</button>
        </div>`;
      lastUpd.textContent = "";
      bind("#state-signin", "click", () => invoke("open_auth"));
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
      bind("#state-signin", "click", () => invoke("open_auth"));
      break;
    case "loaded":
      root.innerHTML = renderLoaded(state);
      lastUpd.textContent = `Updated ${state.last_updated}`;
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

document.getElementById("hide-btn").addEventListener("click", () => invoke("hide_main_window"));
document.getElementById("signin-btn").addEventListener("click", () => invoke("open_auth"));
document.getElementById("quit-btn").addEventListener("click", () => invoke("hide_main_window"));

(async () => {
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
