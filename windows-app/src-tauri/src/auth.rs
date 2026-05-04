use crate::config::ConfigManager;
use crate::models::AppConfig;
use serde::Deserialize;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

#[derive(Deserialize)]
struct Org {
    uuid: String,
}

/// Open the sign-in window. The window navigates to claude.ai/login first;
/// once the user signs in, we navigate to /api/organizations to read the
/// org_id, capture cookies, save config, and close.
pub fn open_auth_window(app: &AppHandle) -> tauri::Result<()> {
    if let Some(existing) = app.get_webview_window("auth") {
        existing.show()?;
        existing.set_focus()?;
        return Ok(());
    }

    let captured = Arc::new(Mutex::new(false));
    let captured_for_handler = captured.clone();
    let app_for_handler = app.clone();

    let url = WebviewUrl::External("https://claude.ai/login".parse().unwrap());
    let _win = WebviewWindowBuilder::new(app, "auth", url)
        .title("Sign in to Claude")
        .inner_size(480.0, 700.0)
        .resizable(true)
        .center()
        .visible(true)
        // Block non-https schemes (defense in depth — javascript:/data:/file: must not navigate).
        .on_navigation(|nav_url| nav_url.scheme() == "https")
        .on_page_load(move |window, payload| {
            if !matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                return;
            }
            let url = payload.url().clone();
            let captured = captured_for_handler.clone();
            let app = app_for_handler.clone();

            tauri::async_runtime::spawn(async move {
                if *captured.lock().unwrap() {
                    return;
                }
                let host = url.host_str().unwrap_or("");
                let path = url.path();

                // Exact-path match prevents tricks like /api/organizationsXYZ.
                if host == "claude.ai" && path == "/api/organizations" {
                    let _ = read_orgs_and_save(&window, &app, &captured).await;
                } else if host == "claude.ai" && path != "/login" && !path.starts_with("/api/") {
                    // User signed in - navigate to org-list endpoint to capture org_id.
                    let _ = window.eval(
                        "window.location.href = 'https://claude.ai/api/organizations';",
                    );
                }
            });
        })
        .build()?;

    Ok(())
}

async fn read_orgs_and_save(
    window: &WebviewWindow,
    app: &AppHandle,
    captured: &Arc<Mutex<bool>>,
) -> tauri::Result<()> {
    // Pull body text. eval_with_callback's callback receives a JSON-encoded string,
    // i.e. the inner string is wrapped in quotes — so we parse it as a JSON Value first.
    let body = match eval_for_string(window, "document.body.innerText").await {
        Some(s) => s,
        None => {
            log::warn!("auth: could not read page body");
            return Ok(());
        }
    };

    let orgs: Vec<Org> = match serde_json::from_str(&body) {
        Ok(o) => o,
        Err(_) => {
            // Don't echo body content — could contain sensitive material.
            log::warn!("auth: page body was not org JSON");
            return Ok(());
        }
    };
    let org = match orgs.into_iter().next() {
        Some(o) => o,
        None => {
            log::warn!("auth: no organizations on the account");
            return Ok(());
        }
    };

    // Cookies are sync in Tauri 2.
    let claude_url: tauri::Url = "https://claude.ai".parse().unwrap();
    let cookies = window.cookies_for_url(claude_url)?;
    let cookie_str = cookies
        .into_iter()
        .map(|c| format!("{}={}", c.name(), c.value()))
        .collect::<Vec<_>>()
        .join("; ");

    if cookie_str.is_empty() {
        log::warn!("auth: cookies came back empty");
        return Ok(());
    }

    let cfg = AppConfig {
        org_id: org.uuid,
        cookie: cookie_str,
    };
    let mgr = ConfigManager::new(app);
    if let Err(e) = mgr.save(&cfg) {
        log::error!("auth: failed to save config: {e}");
        return Ok(());
    }

    *captured.lock().unwrap() = true;
    let _ = app.emit("config-updated", ());
    let _ = window.close();
    Ok(())
}

/// Run a JS expression and return its String result, or None on failure.
/// Tauri 2's eval_with_callback feeds back a JSON-encoded string; we deserialize.
async fn eval_for_string(window: &WebviewWindow, js: &str) -> Option<String> {
    use tokio::sync::oneshot;
    let (tx, rx) = oneshot::channel::<Option<String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));
    let tx_clone = tx.clone();

    let result = window.eval_with_callback(js, move |raw| {
        // raw is e.g. `"hello"` (JSON-encoded). Deserialize to String.
        let parsed: Option<String> = serde_json::from_str(&raw).ok();
        if let Some(t) = tx_clone.lock().unwrap().take() {
            let _ = t.send(parsed);
        }
    });
    if result.is_err() {
        return None;
    }

    rx.await.ok().flatten()
}
