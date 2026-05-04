use crate::config::ConfigManager;
use crate::models::AppConfig;
use serde::Deserialize;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

#[derive(Deserialize)]
struct Org {
    uuid: String,
}

/// Open the sign-in window. Navigates to /login. Once the user signs in,
/// the post-login redirect is detected and we navigate to /api/organizations
/// to read the org_id, capture cookies, save config, and close the window.
pub fn open_auth_window(app: &AppHandle) -> tauri::Result<()> {
    log::info!("auth: open_auth_window invoked");
    if let Some(existing) = app.get_webview_window("auth") {
        log::info!("auth: window already exists, showing");
        existing.show()?;
        existing.set_focus()?;
        return Ok(());
    }

    let captured = Arc::new(Mutex::new(false));
    let captured_for_handler = captured.clone();
    let app_for_handler = app.clone();

    // Best-effort prefill: pull the user's Windows account UPN (often an email).
    let prefill_email = windows_account_email();

    // Persistent webview data directory keeps cookies/local-storage across opens
    // so a returning user with an active session goes straight to /api/organizations
    // without a re-login.
    let data_dir = app
        .path()
        .app_data_dir()
        .ok()
        .map(|d| d.join("auth-webview"));

    let url = WebviewUrl::External("https://claude.ai/login".parse().unwrap());
    let mut builder = WebviewWindowBuilder::new(app, "auth", url)
        .title("Sign in to Claude")
        .inner_size(480.0, 700.0)
        .resizable(true)
        .center()
        .visible(true)
        // Block only dangerous schemes (file: / javascript: / vbscript:).
        // Permit https + about:blank + data: so Claude's login page (which uses
        // sandboxed iframes for OAuth + 3rd-party SSO) can render properly.
        .on_navigation(|nav_url| {
            let scheme = nav_url.scheme();
            !matches!(scheme, "file" | "javascript" | "vbscript")
        });

    if let Some(d) = data_dir {
        let _ = std::fs::create_dir_all(&d);
        builder = builder.data_directory(d);
    }

    let win = builder
        .on_page_load(move |window, payload| {
            if !matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                return;
            }
            let url = payload.url().clone();
            let captured = captured_for_handler.clone();
            let app = app_for_handler.clone();
            let email = prefill_email.clone();

            tauri::async_runtime::spawn(async move {
                if *captured.lock().unwrap() {
                    return;
                }
                let host = url.host_str().unwrap_or("");
                let path = url.path();

                if host == "claude.ai" && path == "/api/organizations" {
                    let _ = read_orgs_and_save(&window, &app, &captured).await;
                } else if host == "claude.ai" && path == "/login" {
                    // Try to prefill the email field if we have a candidate.
                    if let Some(e) = email.as_ref() {
                        let escaped = e.replace('\\', "\\\\").replace('\'', "\\'");
                        let js = format!(
                            r#"(function(){{
                                const el = document.querySelector('input[type=email], input[name=email]');
                                if (el && !el.value) {{
                                    el.value = '{}';
                                    el.dispatchEvent(new Event('input', {{ bubbles: true }}));
                                }}
                            }})();"#,
                            escaped
                        );
                        let _ = window.eval(&js);
                    }
                } else if host == "claude.ai"
                    && !path.starts_with("/api/")
                    && !path.starts_with("/oauth")
                {
                    log::info!(
                        "auth: post-login redirect detected on {path}, navigating to /api/organizations"
                    );
                    let _ = window.eval(
                        "window.location.href = 'https://claude.ai/api/organizations';",
                    );
                }
            });
        })
        .build()
        .inspect_err(|e| log::error!("auth: WebviewWindowBuilder::build failed: {e}"))?;

    log::info!("auth: window created");
    let _ = win.show();
    let _ = win.set_focus();

    // Belt-and-braces: poll cookies every 2s. If we see a sessionKey for
    // claude.ai but the window is parked elsewhere, force-navigate.
    let win_for_poll = win.clone();
    let captured_for_poll = captured.clone();
    tauri::async_runtime::spawn(async move {
        let claude_url: tauri::Url = "https://claude.ai".parse().unwrap();
        for _ in 0..150 {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if *captured_for_poll.lock().unwrap() {
                return;
            }
            if win_for_poll.is_visible().is_err() {
                return;
            }
            let cookies = match win_for_poll.cookies_for_url(claude_url.clone()) {
                Ok(c) => c,
                Err(_) => continue,
            };
            let has_session = cookies.iter().any(|c| c.name() == "sessionKey");
            if !has_session {
                continue;
            }
            let on_orgs_endpoint = win_for_poll
                .url()
                .ok()
                .map(|u| u.path() == "/api/organizations")
                .unwrap_or(false);
            if !on_orgs_endpoint {
                log::info!("auth: poll sees sessionKey but not on /api/organizations, navigating");
                let _ = win_for_poll.eval(
                    "window.location.href = 'https://claude.ai/api/organizations';",
                );
            }
        }
    });

    Ok(())
}

async fn read_orgs_and_save(
    window: &WebviewWindow,
    app: &AppHandle,
    captured: &Arc<Mutex<bool>>,
) -> tauri::Result<()> {
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

async fn eval_for_string(window: &WebviewWindow, js: &str) -> Option<String> {
    use tokio::sync::oneshot;
    let (tx, rx) = oneshot::channel::<Option<String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));
    let tx_clone = tx.clone();

    let result = window.eval_with_callback(js, move |raw| {
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

/// Best-effort: pull the Windows account's UPN/email for prefill.
/// Returns None on any failure — callers must treat this as a hint, not a guarantee.
fn windows_account_email() -> Option<String> {
    use std::process::Command;
    let out = Command::new("whoami")
        .arg("/upn")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if s.contains('@') && s.len() < 128 {
        Some(s)
    } else {
        None
    }
}
