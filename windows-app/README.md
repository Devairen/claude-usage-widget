# Claude Usage — Windows native app

A Tauri 2 desktop app (Rust backend + HTML/CSS/JS frontend) that mirrors the
macOS menu-bar widget. Lives in the system tray, auto-starts with Windows,
auto-shows its window whenever Claude Desktop is running.

## Architecture

```
src-tauri/                 Rust backend
├── src/
│   ├── main.rs            entry point
│   ├── lib.rs             app builder, polling loop, tray, window mgmt
│   ├── usage_service.rs   HTTPS GET to /api/organizations/<org_id>/usage
│   ├── config.rs          read/write %APPDATA%/.../config.json
│   ├── logging.rs         CSV append, history.json ring buffer
│   ├── viewmodel.rs       burn-rate / ETA calculations
│   ├── theme.rs           Claude warm palette + threshold colors
│   ├── tray_icon.rs       runtime arc-icon rendering (tiny-skia)
│   ├── process_watcher.rs sysinfo-based claude.exe detection
│   ├── auth.rs            embedded WebView2 sign-in flow
│   └── models.rs          API + state types
├── Cargo.toml
├── tauri.conf.json        window/bundle/CSP/autostart config
└── capabilities/          Tauri 2 permission grants

src/                       Frontend (vanilla JS)
├── index.html
├── styles.css             Segoe UI Variable, dark/light adaptive
└── main.js                renders state pushed by Rust via events
```

## Build prerequisites

- **Rust** (stable). Install from https://rustup.rs.
- **Node.js 18+** for the Tauri CLI.
- **WebView2 Runtime**. Pre-installed on Win11 + modern Win10. The bundled
  installer auto-downloads it if missing.

## Commands

```powershell
npm install
npm run dev          # dev mode with HMR
npm run build        # release build, produces installers
```

Output: `src-tauri/target/release/bundle/`
- `nsis/Claude Usage_<ver>_x64-setup.exe`
- `msi/Claude Usage_<ver>_x64_en-US.msi`

## Runtime files

`%APPDATA%\dev.devairen.claude-usage\` (resolved via Tauri's `app_data_dir`):

| File | Purpose |
|---|---|
| `config.json` | `org_id` + cookie. Written by the auth flow. |
| `usage-log.csv` | Append-only poll log. Same schema as the Python widget's CSV. |
| `history.json` | Last 60 samples, used for burn-rate / ETA bootstrap. |

## Auto-show behavior

Process watcher polls every 5 s for `claude.exe`. When it starts, the
widget window is shown (at last-saved position) unless the user manually
closed it. When Claude exits, the widget hides unless the user manually
opened it. Manual overrides reset on the next Claude state transition.

## Auth flow

Mirrors the Mac app:
1. Open `https://claude.ai/login` in an embedded WebView2 window.
2. After the user signs in, navigate to `https://claude.ai/api/organizations`.
3. Read response body via `eval("document.body.innerText")`.
4. Extract `org_id` from the JSON.
5. Read cookies for `claude.ai` via `webview.cookies_for_url`.
6. Save both to `config.json`.

No cookie pasting required.

## CSP

```
default-src 'self';
img-src 'self' data: asset: blob:;
style-src 'self' 'unsafe-inline';
script-src 'self';
connect-src 'self' ipc: http://ipc.localhost
```

The auth window navigates to `https://claude.ai` directly via `WebviewUrl::External`
(not subject to the main app's CSP). The main popover only loads bundled
assets — no network from the UI side; all HTTP happens in the Rust backend.

## Notes / known limitations

- Notifications dedupe is process-lifetime, not session-lifetime. If you
  restart the app mid-session you may get a repeat 80%/95% toast.
- Window state plugin persists last position/size. First launch centers.
- Tray icon uses a custom-rendered arc (`tiny-skia`); it's redrawn each poll
  with the current 5h utilization color.
