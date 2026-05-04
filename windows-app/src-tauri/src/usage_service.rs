use crate::models::{UsageData, UsageError};
use once_cell::sync::Lazy;
use regex::Regex;
use reqwest::Client;
use std::time::Duration;

static UUID_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$").unwrap()
});

static CLIENT: Lazy<Client> = Lazy::new(|| {
    Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
        )
        .build()
        .expect("failed to build reqwest client")
});

pub async fn fetch_usage(org_id: &str, cookie: &str) -> Result<UsageData, UsageError> {
    if !UUID_RE.is_match(org_id) {
        return Err(UsageError::InvalidResponse);
    }

    // Defensive: strip CR/LF to prevent header-injection if config.json was tampered with.
    let cookie = cookie.replace(['\r', '\n'], "");

    let url = format!("https://claude.ai/api/organizations/{}/usage", org_id);

    let resp = CLIENT
        .get(&url)
        .header("Cookie", &cookie)
        .header("Accept", "*/*")
        .header("Referer", "https://claude.ai/settings/usage")
        .header(
            "Sec-Ch-Ua",
            "\"Google Chrome\";v=\"147\", \"Not.A/Brand\";v=\"8\", \"Chromium\";v=\"147\"",
        )
        .header("Sec-Ch-Ua-Mobile", "?0")
        .header("Sec-Ch-Ua-Platform", "\"Windows\"")
        .header("Sec-Fetch-Dest", "empty")
        .header("Sec-Fetch-Mode", "cors")
        .header("Sec-Fetch-Site", "same-origin")
        .send()
        .await
        .map_err(|e| UsageError::Network(e.to_string()))?;

    let status = resp.status().as_u16();
    match status {
        200 => resp
            .json::<UsageData>()
            .await
            .map_err(|_| UsageError::InvalidResponse),
        401 | 403 => Err(UsageError::AuthFailed),
        other => Err(UsageError::HttpError(other)),
    }
}
