use axum::{
    extract::Json,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use tracing::info;

#[derive(Debug, Serialize, Deserialize)]
struct CaptureEvent {
    event: String,
    #[serde(default)]
    distinct_id: String,
    #[serde(default)]
    properties: serde_json::Value,
}

#[derive(Debug, Serialize, Deserialize)]
struct BatchEvents {
    #[serde(default)]
    api_key: String,
    batch: Vec<CaptureEvent>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let port: u16 = std::env::var("CAPTURE_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(18000);

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/capture", post(capture))
        .route("/batch", post(batch))
        .route("/batch/", post(batch));

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    info!("🦔 PostHog Capture Ingestion Service listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "{\"status\":\"ok\",\"service\":\"capture\"}")
}

async fn capture(Json(payload): Json<CaptureEvent>) -> impl IntoResponse {
    info!(event = %payload.event, distinct_id = %payload.distinct_id, "Ingested event");
    (StatusCode::OK, Json(serde_json::json!({"status": 1})))
}

async fn batch(Json(payload): Json<BatchEvents>) -> impl IntoResponse {
    info!(batch_size = payload.batch.len(), "Ingested event batch");
    (StatusCode::OK, Json(serde_json::json!({"status": 1, "processed": payload.batch.len()})))
}
