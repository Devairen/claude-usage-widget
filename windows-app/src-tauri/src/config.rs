use crate::models::AppConfig;
use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;
use tauri::{AppHandle, Manager};

pub struct ConfigManager {
    config_path: PathBuf,
}

impl ConfigManager {
    pub fn new(app: &AppHandle) -> Self {
        let app_dir = app
            .path()
            .app_data_dir()
            .expect("failed to resolve app_data_dir");
        let _ = fs::create_dir_all(&app_dir);
        let config_path = app_dir.join("config.json");
        Self { config_path }
    }

    pub fn load(&self) -> Option<AppConfig> {
        let bytes = fs::read(&self.config_path).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn save(&self, config: &AppConfig) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(config)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        // Atomic write via temp + rename
        let tmp = self.config_path.with_extension("json.tmp");
        fs::write(&tmp, &bytes)?;
        fs::rename(&tmp, &self.config_path)?;
        Ok(())
    }

    pub fn config_age_days(&self) -> Option<i64> {
        let meta = fs::metadata(&self.config_path).ok()?;
        let modified = meta.modified().ok()?;
        let age = SystemTime::now().duration_since(modified).ok()?;
        Some((age.as_secs() / 86400) as i64)
    }

    #[allow(dead_code)]
    pub fn path(&self) -> &PathBuf {
        &self.config_path
    }
}
