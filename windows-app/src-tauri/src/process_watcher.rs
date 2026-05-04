use sysinfo::{ProcessRefreshKind, RefreshKind, System};

const CLAUDE_PROCESS_NAMES: &[&str] = &["claude.exe", "Claude.exe", "claude", "Claude"];

/// Returns true if any process matching Claude Desktop is running.
pub fn is_claude_running() -> bool {
    let mut sys = System::new_with_specifics(
        RefreshKind::new().with_processes(ProcessRefreshKind::new()),
    );
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);

    sys.processes().values().any(|p| {
        let name = p.name().to_string_lossy();
        CLAUDE_PROCESS_NAMES.iter().any(|n| name.eq_ignore_ascii_case(n))
    })
}
