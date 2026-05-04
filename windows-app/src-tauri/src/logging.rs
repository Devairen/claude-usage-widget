use crate::models::UsageData;
use chrono::Local;
use serde_json::Value;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

pub struct LoggingService {
    csv_path: PathBuf,
    history_path: PathBuf,
}

impl LoggingService {
    pub fn new(app: &AppHandle) -> Self {
        let app_dir = app
            .path()
            .app_data_dir()
            .expect("failed to resolve app_data_dir");
        let _ = fs::create_dir_all(&app_dir);
        Self {
            csv_path: app_dir.join("usage-log.csv"),
            history_path: app_dir.join("history.json"),
        }
    }

    pub fn log(&self, data: &UsageData) {
        let _ = self.append_csv(data);
        let _ = self.append_history(data);
    }

    fn append_csv(&self, data: &UsageData) -> std::io::Result<()> {
        let timestamp = Local::now().format("%Y-%m-%dT%H:%M:%S").to_string();
        let five = data
            .five_hour
            .as_ref()
            .and_then(|e| e.utilization)
            .unwrap_or(0.0);
        let week = data
            .seven_day
            .as_ref()
            .and_then(|e| e.utilization)
            .unwrap_or(0.0);
        let line = format!("{},{:.2},{:.2}\n", timestamp, five, week);

        let exists = self.csv_path.exists();
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.csv_path)?;
        if !exists {
            f.write_all(b"timestamp,five_hour_pct,weekly_pct\n")?;
        }
        f.write_all(line.as_bytes())?;
        Ok(())
    }

    fn append_history(&self, data: &UsageData) -> std::io::Result<()> {
        let bucket = (chrono::Utc::now().timestamp() / 60) as f64;
        let pct = data
            .five_hour
            .as_ref()
            .and_then(|e| e.utilization)
            .unwrap_or(0.0);

        let mut history: Vec<Vec<f64>> = fs::read(&self.history_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();

        history.push(vec![bucket, pct]);
        if history.len() > 60 {
            let drop = history.len() - 60;
            history.drain(0..drop);
        }

        let bytes = serde_json::to_vec(&history)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        let tmp = self.history_path.with_extension("json.tmp");
        fs::write(&tmp, &bytes)?;
        fs::rename(&tmp, &self.history_path)?;
        Ok(())
    }

    pub fn load_history(&self) -> Vec<(f64, f64)> {
        let raw: Value = fs::read(&self.history_path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Value::Array(vec![]));
        let arr = match raw {
            Value::Array(a) => a,
            _ => return vec![],
        };
        arr.into_iter()
            .filter_map(|v| {
                let parts = v.as_array()?;
                if parts.len() < 2 {
                    return None;
                }
                Some((parts[0].as_f64()?, parts[1].as_f64()?))
            })
            .collect()
    }
}
