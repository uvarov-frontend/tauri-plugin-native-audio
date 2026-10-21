use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioState {
    pub status: String, // idle | loading | playing | ended | error
    pub current_time: f64,
    pub duration: f64,
    pub is_playing: bool,
    pub buffering: bool,
    pub rate: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Default for NativeAudioState {
    fn default() -> Self {
        Self {
            status: "idle".into(),
            current_time: 0.0,
            duration: 0.0,
            is_playing: false,
            buffering: false,
            rate: 1.0,
            error: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioProgressCheckpoint {
    pub id: i64,
    pub current_time: f64,
    pub updated_at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetSourceArgs {
    pub src: String,
    pub id: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artwork_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SeekToArgs {
    pub position: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetRateArgs {
    pub rate: f64,
}
