mod auth;
mod config;
mod logging;
mod models;
mod process_watcher;
mod theme;
mod tray_icon;
mod usage_service;
mod viewmodel;

use crate::config::ConfigManager;
use crate::logging::LoggingService;
use crate::models::{UsageError, WidgetState};
use crate::tray_icon::IconKind;
use crate::viewmodel::ViewModel;
use chrono::TimeZone;
use std::sync::Arc;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Listener, Manager, RunEvent};

const POLL_SECS: u64 = 60;
const PROCESS_WATCH_SECS: u64 = 5;

pub struct AppState {
    pub view_model: Arc<ViewModel>,
    pub user_closed_window: std::sync::atomic::AtomicBool,
    pub user_opened_window: std::sync::atomic::AtomicBool,
    pub last_claude_running: std::sync::atomic::AtomicBool,
}

#[tauri::command]
fn get_state(state: tauri::State<'_, AppState>) -> WidgetState {
    state.view_model.last_state()
}

#[derive(serde::Serialize)]
pub struct HistoryPoint {
    /// Unix seconds (UTC).
    pub ts: i64,
    pub five_hour: f64,
    pub weekly: f64,
}

/// Read usage-log.csv and return the rows (filtered to the last `days` days).
/// Frontend renders this in the history popup.
#[tauri::command]
fn get_history(app: AppHandle, days: u32) -> Result<Vec<HistoryPoint>, String> {
    let app_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;
    let csv_path = app_dir.join("usage-log.csv");
    if !csv_path.exists() {
        return Ok(Vec::new());
    }
    let content = std::fs::read_to_string(&csv_path).map_err(|e| e.to_string())?;
    let cutoff = chrono::Utc::now() - chrono::Duration::days(days as i64);

    let mut out = Vec::new();
    for (i, line) in content.lines().enumerate() {
        if i == 0 {
            continue; // header
        }
        let parts: Vec<&str> = line.splitn(3, ',').collect();
        if parts.len() < 3 {
            continue;
        }
        // Timestamp is local-time ISO 8601 without offset. Parse naively, then
        // attach the local offset.
        let ndt = match chrono::NaiveDateTime::parse_from_str(parts[0], "%Y-%m-%dT%H:%M:%S") {
            Ok(d) => d,
            Err(_) => continue,
        };
        let local = match chrono::Local.from_local_datetime(&ndt) {
            chrono::LocalResult::Single(d) => d,
            chrono::LocalResult::Ambiguous(d, _) => d,
            chrono::LocalResult::None => continue,
        };
        let ts_utc = local.with_timezone(&chrono::Utc);
        if ts_utc < cutoff {
            continue;
        }
        let five = parts[1].parse::<f64>().unwrap_or(0.0);
        let week = parts[2].parse::<f64>().unwrap_or(0.0);
        out.push(HistoryPoint {
            ts: ts_utc.timestamp(),
            five_hour: five,
            weekly: week,
        });
    }
    Ok(out)
}

/// Settings stored alongside config. UI toggles map to these fields.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct Settings {
    /// Whether to launch on login.
    autostart: Option<bool>,
    /// Whether to show the per-model section even when present.
    show_models: Option<bool>,
    /// Whether to show the sparkline strip.
    show_sparkline: Option<bool>,
    /// Whether to fire notifications when 5h % crosses a threshold.
    notify_enabled: Option<bool>,
    /// Thresholds (e.g. [80.0, 90.0]) at which to fire a notification.
    notify_thresholds: Option<Vec<f64>>,
}

fn settings_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_data_dir().ok().map(|d| d.join("settings.json"))
}

fn load_settings(app: &AppHandle) -> Settings {
    settings_path(app)
        .and_then(|p| std::fs::read(&p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn save_settings(app: &AppHandle, s: &Settings) -> std::io::Result<()> {
    let path = settings_path(app)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no app dir"))?;
    let bytes = serde_json::to_vec_pretty(s)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

#[tauri::command]
fn get_settings(app: AppHandle) -> Settings {
    load_settings(&app)
}

#[tauri::command]
fn set_settings(app: AppHandle, settings: Settings) -> Result<(), String> {
    // Apply autostart side-effect immediately if set.
    if let Some(want) = settings.autostart {
        use tauri_plugin_autostart::ManagerExt;
        let mgr = app.autolaunch();
        let is = mgr.is_enabled().unwrap_or(false);
        if want && !is {
            let _ = mgr.enable();
        } else if !want && is {
            let _ = mgr.disable();
        }
    }
    save_settings(&app, &settings).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_auth(app: AppHandle) -> Result<(), String> {
    auth::open_auth_window(&app).map_err(|e| e.to_string())
}

#[tauri::command]
fn sign_out(app: AppHandle) -> Result<(), String> {
    let mgr = ConfigManager::new(&app);
    let path = mgr.path();
    if path.exists() {
        std::fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    // Wipe the auth WebView2 store too — otherwise next "Sign in" would silently
    // re-use the still-valid claude.ai sessionKey and look like nothing happened.
    if let Ok(app_dir) = app.path().app_data_dir() {
        let auth_dir = app_dir.join("auth-webview");
        if auth_dir.exists() {
            // Best-effort: webview2 may hold a lock on some files. Ignore errors.
            let _ = std::fs::remove_dir_all(&auth_dir);
        }
    }
    // Close the auth window if it's open (its internal state is now stale).
    if let Some(win) = app.get_webview_window("auth") {
        let _ = win.close();
    }
    if let Some(state) = app.try_state::<AppState>() {
        state.view_model.set_state(WidgetState::NeedsConfig);
        state.view_model.set_cookie_age(None);
    }
    let _ = app.emit("state-updated", WidgetState::NeedsConfig);
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(tray_icon::render(IconKind::NeedsConfig)));
    }
    Ok(())
}

#[tauri::command]
fn show_main_window(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    state
        .user_closed_window
        .store(false, std::sync::atomic::Ordering::Relaxed);
    state
        .user_opened_window
        .store(true, std::sync::atomic::Ordering::Relaxed);
    if let Some(win) = app.get_webview_window("main") {
        win.show().map_err(|e| e.to_string())?;
        win.set_focus().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn hide_main_window(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    use tauri_plugin_window_state::{AppHandleExt, StateFlags};
    state
        .user_closed_window
        .store(true, std::sync::atomic::Ordering::Relaxed);
    state
        .user_opened_window
        .store(false, std::sync::atomic::Ordering::Relaxed);
    let _ = app.save_window_state(StateFlags::all());
    if let Some(win) = app.get_webview_window("main") {
        win.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![
            get_state,
            open_auth,
            sign_out,
            show_main_window,
            hide_main_window,
            get_history,
            get_settings,
            set_settings
        ])
        .setup(|app| {
            let state = AppState {
                view_model: Arc::new(ViewModel::new()),
                user_closed_window: std::sync::atomic::AtomicBool::new(false),
                user_opened_window: std::sync::atomic::AtomicBool::new(false),
                last_claude_running: std::sync::atomic::AtomicBool::new(false),
            };

            // Bootstrap burn rate from disk
            let logger = LoggingService::new(&app.handle());
            state.view_model.bootstrap_from_history(&logger.load_history());

            // Cookie age
            let mgr = ConfigManager::new(&app.handle());
            state.view_model.set_cookie_age(mgr.config_age_days());

            app.manage(state);

            // Tray
            build_tray(&app.handle())?;

            // Hide main window on launch (autostart silent)
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.hide();
            }

            // First-run: open auth if no config
            if mgr.load().is_none() {
                let app_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let _ = auth::open_auth_window(&app_handle);
                });
            }

            // React to config-updated events (auth flow saved a new config)
            {
                let app_handle = app.handle().clone();
                app.listen("config-updated", move |_| {
                    let app_handle = app_handle.clone();
                    tauri::async_runtime::spawn(async move {
                        poll_once(&app_handle).await;
                    });
                });
            }

            // Polling loop
            {
                let app_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    poll_once(&app_handle).await;
                    let mut tick = tokio::time::interval(Duration::from_secs(POLL_SECS));
                    tick.tick().await; // skip immediate (already polled)
                    loop {
                        tick.tick().await;
                        poll_once(&app_handle).await;
                    }
                });
            }

            // Process watcher loop
            {
                let app_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let mut tick =
                        tokio::time::interval(Duration::from_secs(PROCESS_WATCH_SECS));
                    loop {
                        tick.tick().await;
                        check_claude_running(&app_handle);
                    }
                });
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            use tauri_plugin_window_state::{AppHandleExt, StateFlags};
            if let RunEvent::WindowEvent { label, event, .. } = event {
                if label == "main" {
                    match &event {
                        tauri::WindowEvent::CloseRequested { api, .. } => {
                            // Persist size/position before we swallow the close.
                            let _ = app.save_window_state(StateFlags::all());
                            if let Some(state) = app.try_state::<AppState>() {
                                state
                                    .user_closed_window
                                    .store(true, std::sync::atomic::Ordering::Relaxed);
                                state
                                    .user_opened_window
                                    .store(false, std::sync::atomic::Ordering::Relaxed);
                            }
                            api.prevent_close();
                            if let Some(win) = app.get_webview_window("main") {
                                let _ = win.hide();
                            }
                        }
                        // Persist on every resize/move so power-cut or kill doesn't lose state.
                        tauri::WindowEvent::Resized(_) | tauri::WindowEvent::Moved(_) => {
                            let _ = app.save_window_state(StateFlags::all());
                        }
                        _ => {}
                    }
                }
            }
        });
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let show_i = MenuItem::with_id(app, "show", "Show", true, None::<&str>)?;
    let hide_i = MenuItem::with_id(app, "hide", "Hide", true, None::<&str>)?;
    let signin_i = MenuItem::with_id(app, "signin", "Sign in to Claude", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show_i, &hide_i, &signin_i, &quit_i])?;

    TrayIconBuilder::with_id("main")
        .icon(tray_icon::render(IconKind::Loading))
        .icon_as_template(false)
        .tooltip("Claude Usage")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(state) = app.try_state::<AppState>() {
                    state
                        .user_closed_window
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    state
                        .user_opened_window
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                }
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                }
            }
            "hide" => {
                if let Some(state) = app.try_state::<AppState>() {
                    state
                        .user_closed_window
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                }
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.hide();
                }
            }
            "signin" => {
                let _ = auth::open_auth_window(app);
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(win) = app.get_webview_window("main") {
                    let visible = win.is_visible().unwrap_or(false);
                    if visible {
                        let _ = win.hide();
                        if let Some(state) = app.try_state::<AppState>() {
                            state
                                .user_closed_window
                                .store(true, std::sync::atomic::Ordering::Relaxed);
                        }
                    } else {
                        let _ = win.show();
                        let _ = win.set_focus();
                        if let Some(state) = app.try_state::<AppState>() {
                            state
                                .user_closed_window
                                .store(false, std::sync::atomic::Ordering::Relaxed);
                            state
                                .user_opened_window
                                .store(true, std::sync::atomic::Ordering::Relaxed);
                        }
                    }
                }
            }
        })
        .build(app)?;

    Ok(())
}

async fn poll_once(app: &AppHandle) {
    let mgr = ConfigManager::new(app);
    let cfg = match mgr.load() {
        Some(c) => c,
        None => {
            push_state(app, WidgetState::NeedsConfig);
            update_tray_icon(app, IconKind::NeedsConfig);
            return;
        }
    };

    match usage_service::fetch_usage(&cfg.org_id, &cfg.cookie).await {
        Ok(data) => {
            let state = app.state::<AppState>();
            state.view_model.set_cookie_age(mgr.config_age_days());
            let new_state = state.view_model.build_loaded_state(&data);
            push_state(app, new_state.clone());

            let pct = state.view_model.five_hour_pct();
            update_tray_icon(app, IconKind::Pct(pct));

            // Persist to disk
            let logger = LoggingService::new(app);
            logger.log(&data);

            // Notifications at 80% / 95% — TODO: dedupe per session in v0.2
            maybe_notify(app, pct);
        }
        Err(UsageError::AuthFailed) => {
            push_state(app, WidgetState::AuthFailed);
            update_tray_icon(app, IconKind::AuthFailed);
        }
        Err(e) => {
            push_state(
                app,
                WidgetState::Error {
                    message: e.to_string(),
                },
            );
            update_tray_icon(app, IconKind::Error);
        }
    }
}

fn push_state(app: &AppHandle, state: WidgetState) {
    if let Some(s) = app.try_state::<AppState>() {
        s.view_model.set_state(state.clone());
    }
    let _ = app.emit("state-updated", state);
}

fn update_tray_icon(app: &AppHandle, kind: IconKind) {
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(tray_icon::render(kind)));
    }
}

fn maybe_notify(app: &AppHandle, pct: f64) {
    use tauri_plugin_notification::NotificationExt;
    static LAST: once_cell::sync::Lazy<std::sync::Mutex<f64>> =
        once_cell::sync::Lazy::new(|| std::sync::Mutex::new(0.0));
    let mut last = LAST.lock().unwrap();

    let settings = load_settings(app);
    let enabled = settings.notify_enabled.unwrap_or(true);
    let thresholds = settings
        .notify_thresholds
        .unwrap_or_else(|| vec![80.0, 90.0]);

    if enabled {
        // Fire from highest crossed threshold down — but we only want the
        // single most-recent crossing per poll, so iterate descending and
        // notify on the first match.
        let mut sorted = thresholds.clone();
        sorted.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
        for t in &sorted {
            if *last < *t && pct >= *t {
                let _ = app
                    .notification()
                    .builder()
                    .title("Claude Usage")
                    .body(format!("5h session at {:.0}% (crossed {:.0}%)", pct, t))
                    .show();
                break;
            }
        }
    }

    // Reset tracking on session reset (large drop)
    if pct < *last - 30.0 {
        *last = 0.0;
    } else {
        *last = pct;
    }
}

fn check_claude_running(app: &AppHandle) {
    use std::sync::atomic::Ordering;
    let running = process_watcher::is_claude_running();
    let state = match app.try_state::<AppState>() {
        Some(s) => s,
        None => return,
    };
    let prev = state.last_claude_running.swap(running, Ordering::Relaxed);

    if running == prev {
        return;
    }

    let win = match app.get_webview_window("main") {
        Some(w) => w,
        None => return,
    };

    if running {
        // Claude just started — auto-show the window unless user closed it manually
        if !state.user_closed_window.load(Ordering::Relaxed) {
            let _ = win.show();
        }
    } else {
        // Claude just closed — auto-hide unless user manually opened it
        if !state.user_opened_window.load(Ordering::Relaxed) {
            let _ = win.hide();
        }
    }
}
