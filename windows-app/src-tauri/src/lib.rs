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

#[tauri::command]
fn open_auth(app: AppHandle) -> Result<(), String> {
    auth::open_auth_window(&app).map_err(|e| e.to_string())
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
    state
        .user_closed_window
        .store(true, std::sync::atomic::Ordering::Relaxed);
    state
        .user_opened_window
        .store(false, std::sync::atomic::Ordering::Relaxed);
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
            show_main_window,
            hide_main_window
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
            if let RunEvent::WindowEvent { label, event, .. } = event {
                if label == "main" {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        // User closed the window — record intent, hide instead of quitting
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
    let crossed = |t: f64| *last < t && pct >= t;
    if crossed(95.0) {
        let _ = app
            .notification()
            .builder()
            .title("Claude Usage")
            .body(format!("5h session at {:.0}% — close to the limit", pct))
            .show();
    } else if crossed(80.0) {
        let _ = app
            .notification()
            .builder()
            .title("Claude Usage")
            .body(format!("5h session at {:.0}%", pct))
            .show();
    }
    // Reset on session reset (large drop)
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
