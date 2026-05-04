use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageData {
    pub five_hour: Option<UsageEntry>,
    pub seven_day: Option<UsageEntry>,
    pub seven_day_sonnet: Option<UsageEntry>,
    pub seven_day_opus: Option<UsageEntry>,
    pub seven_day_omelette: Option<UsageEntry>,
    pub extra_usage: Option<ExtraUsage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageEntry {
    pub utilization: Option<f64>,
    pub resets_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtraUsage {
    pub is_enabled: Option<bool>,
    pub used_credits: Option<f64>,
    pub monthly_limit: Option<f64>,
    pub currency: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub org_id: String,
    pub cookie: String,
}

#[derive(Debug, thiserror::Error)]
pub enum UsageError {
    #[error("Authentication failed - refresh your cookie")]
    AuthFailed,
    #[error("Invalid response from server")]
    InvalidResponse,
    #[error("HTTP error {0}")]
    HttpError(u16),
    #[error("Network error: {0}")]
    Network(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum WidgetState {
    Loading,
    NeedsConfig,
    AuthFailed,
    Loaded {
        five_hour_pct: f64,
        seven_day_pct: f64,
        five_hour_resets_at: Option<String>,
        seven_day_resets_at: Option<String>,
        models: Vec<ModelUsage>,
        extra: Option<ExtraUsage>,
        burn_rate_per_min: Option<f64>,
        minutes_to_limit: Option<f64>,
        will_hit_limit: bool,
        last_updated: String,
        cookie_age_days: Option<i64>,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelUsage {
    pub name: String,
    pub percentage: f64,
}
