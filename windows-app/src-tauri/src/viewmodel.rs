use crate::models::{ModelUsage, UsageData, WidgetState};
use chrono::{DateTime, Local, Utc};
use std::sync::Mutex;

/// Holds the rolling buffer of recent (instant, pct) samples used for burn-rate
/// estimation. Mirrors UsageViewModel.swift on the Mac.
pub struct ViewModel {
    samples: Mutex<Vec<(DateTime<Utc>, f64)>>,
    last_state: Mutex<WidgetState>,
    cookie_age_days: Mutex<Option<i64>>,
}

impl ViewModel {
    pub fn new() -> Self {
        Self {
            samples: Mutex::new(Vec::new()),
            last_state: Mutex::new(WidgetState::Loading),
            cookie_age_days: Mutex::new(None),
        }
    }

    /// Seed the burn-rate buffer from on-disk history.
    /// Keeps the last 5 hours so the projection covers a full session window.
    pub fn bootstrap_from_history(&self, history: &[(f64, f64)]) {
        let now = Utc::now();
        let cutoff = now - chrono::Duration::hours(5);
        let mut samples = self.samples.lock().unwrap();
        for (bucket, pct) in history {
            if let Some(date) = DateTime::<Utc>::from_timestamp((*bucket as i64) * 60, 0) {
                if date >= cutoff {
                    samples.push((date, *pct));
                }
            }
        }
    }

    pub fn set_cookie_age(&self, age: Option<i64>) {
        *self.cookie_age_days.lock().unwrap() = age;
    }

    pub fn set_state(&self, state: WidgetState) {
        *self.last_state.lock().unwrap() = state;
    }

    pub fn last_state(&self) -> WidgetState {
        self.last_state.lock().unwrap().clone()
    }

    pub fn five_hour_pct(&self) -> f64 {
        match &*self.last_state.lock().unwrap() {
            WidgetState::Loaded { five_hour_pct, .. } => *five_hour_pct,
            _ => 0.0,
        }
    }

    /// Convert a fetched UsageData into a Loaded state, also updating the
    /// burn-rate buffer.
    pub fn build_loaded_state(&self, data: &UsageData) -> WidgetState {
        let five_pct = data
            .five_hour
            .as_ref()
            .and_then(|e| e.utilization)
            .unwrap_or(0.0);
        let week_pct = data
            .seven_day
            .as_ref()
            .and_then(|e| e.utilization)
            .unwrap_or(0.0);

        self.add_sample(Utc::now(), five_pct);
        let burn = self.burn_rate_per_min();
        let to_limit = self.minutes_to_limit(five_pct, burn);
        let to_reset = self.minutes_to_reset(data.five_hour.as_ref().and_then(|e| e.resets_at.as_deref()));
        let will_hit = matches!((to_limit, to_reset), (Some(a), Some(b)) if a < b);

        // Show every model the API returns (don't hide 0%, that's useful info).
        let mut models: Vec<ModelUsage> = Vec::new();
        if let Some(u) = data.seven_day_sonnet.as_ref().and_then(|e| e.utilization) {
            models.push(ModelUsage { name: "Sonnet".into(), percentage: u });
        }
        if let Some(u) = data.seven_day_opus.as_ref().and_then(|e| e.utilization) {
            models.push(ModelUsage { name: "Opus".into(), percentage: u });
        }
        if let Some(u) = data.seven_day_omelette.as_ref().and_then(|e| e.utilization) {
            models.push(ModelUsage { name: "Design".into(), percentage: u });
        }

        let samples_minutes = self.samples_minutes();
        let spark = self.recent_spark(60);

        WidgetState::Loaded {
            five_hour_pct: five_pct,
            seven_day_pct: week_pct,
            five_hour_resets_at: data.five_hour.as_ref().and_then(|e| e.resets_at.clone()),
            seven_day_resets_at: data.seven_day.as_ref().and_then(|e| e.resets_at.clone()),
            models,
            extra: data.extra_usage.clone(),
            burn_rate_per_min: burn,
            minutes_to_limit: to_limit,
            will_hit_limit: will_hit,
            burn_rate_samples_minutes: samples_minutes,
            spark,
            last_updated: Local::now().format("%H:%M:%S").to_string(),
            cookie_age_days: *self.cookie_age_days.lock().unwrap(),
        }
    }

    fn samples_minutes(&self) -> f64 {
        let s = self.samples.lock().unwrap();
        if s.len() < 2 {
            return 0.0;
        }
        let first = s.first().unwrap();
        let last = s.last().unwrap();
        (last.0 - first.0).num_seconds() as f64 / 60.0
    }

    /// Returns the most recent N samples' percentages, oldest first.
    fn recent_spark(&self, n: usize) -> Vec<f64> {
        let s = self.samples.lock().unwrap();
        let len = s.len();
        let start = len.saturating_sub(n);
        s[start..].iter().map(|(_, pct)| *pct).collect()
    }

    fn add_sample(&self, when: DateTime<Utc>, pct: f64) {
        let mut s = self.samples.lock().unwrap();
        s.push((when, pct));
        // Keep last 5 hours so projection covers the full session window.
        let cutoff = when - chrono::Duration::hours(5);
        s.retain(|(d, _)| *d >= cutoff);
        // Detect resets: if pct drops by >20pp, discard older samples
        // (the session reset wiped your usage to ~0).
        if s.len() >= 2 {
            for i in (1..s.len()).rev() {
                if s[i].1 < s[i - 1].1 - 20.0 {
                    let kept: Vec<_> = s[i..].to_vec();
                    *s = kept;
                    break;
                }
            }
        }
    }

    fn burn_rate_per_min(&self) -> Option<f64> {
        let s = self.samples.lock().unwrap();
        if s.len() < 3 {
            return None;
        }
        let first = s.first()?;
        let last = s.last()?;
        let mins = (last.0 - first.0).num_seconds() as f64 / 60.0;
        if mins < 2.0 {
            return None;
        }
        let delta = last.1 - first.1;
        if delta <= 0.5 {
            return None;
        }
        Some(delta / mins)
    }

    fn minutes_to_limit(&self, current_pct: f64, burn: Option<f64>) -> Option<f64> {
        let rate = burn?;
        if rate <= 0.0 {
            return None;
        }
        let remaining = 100.0 - current_pct;
        if remaining <= 0.0 {
            return None;
        }
        Some(remaining / rate)
    }

    fn minutes_to_reset(&self, iso: Option<&str>) -> Option<f64> {
        let s = iso?;
        let date = DateTime::parse_from_rfc3339(s).ok()?;
        let now = Utc::now();
        let mins = (date.with_timezone(&Utc) - now).num_seconds() as f64 / 60.0;
        if mins > 0.0 {
            Some(mins)
        } else {
            None
        }
    }
}

impl Default for ViewModel {
    fn default() -> Self {
        Self::new()
    }
}
