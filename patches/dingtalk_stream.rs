//! DingTalk Robot channel adapter — **Stream mode**.
//!
//! Connects to DingTalk via the Stream protocol (outbound WebSocket).
//! No public IP or webhook server required. Incoming messages arrive over
//! the persistent WebSocket connection; replies are sent via the OpenAPI
//! message endpoint using an OAuth2 access token.
//!
//! Configuration reuses the existing `DingTalkConfig` fields:
//! - `access_token_env` → stores the **App Key** (client_id)
//! - `secret_env`       → stores the **App Secret** (client_secret)
//! - `webhook_port`     → ignored (kept for constructor compatibility)

use crate::types::{
    split_message, ChannelAdapter, ChannelContent, ChannelMessage, ChannelType, ChannelUser,
};
use async_trait::async_trait;
use chrono::Utc;
use dashmap::DashMap;
use futures::{SinkExt, Stream, StreamExt};
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, watch, Mutex};
use tracing::{debug, error, info, warn};
use zeroize::Zeroizing;

/// Text chunk limit matching CoPaw's default (2000 chars per message).
const MAX_MESSAGE_LEN: usize = 2000;

/// DingTalk Stream gateway endpoint for obtaining a WebSocket ticket.
const STREAM_OPEN_URL: &str = "https://api.dingtalk.com/v1.0/gateway/connections/open";
/// DingTalk OAuth2 token endpoint.
const TOKEN_URL: &str = "https://api.dingtalk.com/v1.0/oauth2/accessToken";
/// DingTalk OpenAPI: reply to a bot message (using `processQueryKey`).
const REPLY_URL: &str =
    "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend";

/// Heartbeat interval — send a WebSocket ping every 30 seconds.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
/// Reconnect back-off base.
const RECONNECT_BASE: Duration = Duration::from_secs(2);
/// Maximum reconnect delay.
const RECONNECT_MAX: Duration = Duration::from_secs(60);

// ── Adapter ─────────────────────────────────────────────────────────

/// DingTalk Robot channel adapter (Stream mode).
///
/// Uses DingTalk's Stream protocol (outbound WebSocket) to receive messages
/// and the OpenAPI to send replies. No inbound HTTP server is needed.
pub struct DingTalkAdapter {
    /// App Key (client_id). Field name kept as `access_token` for compat.
    app_key: Zeroizing<String>,
    /// App Secret (client_secret).
    app_secret: Zeroizing<String>,
    /// HTTP client shared across tasks.
    client: reqwest::Client,
    /// Cached OAuth2 access token + expiry.
    token_cache: Arc<Mutex<Option<(String, i64)>>>,
    /// Cached sessionWebhook URLs: staffId → (webhookUrl, expiryMs).
    /// Populated on each incoming message; used by `send()` for replies.
    webhook_cache: Arc<DashMap<String, (String, i64)>>,
    /// Shutdown signal.
    shutdown_tx: Arc<watch::Sender<bool>>,
    shutdown_rx: watch::Receiver<bool>,
}

impl DingTalkAdapter {
    /// Create a new DingTalk adapter.
    ///
    /// Signature is intentionally compatible with the original webhook adapter
    /// so that `channel_bridge.rs` requires **zero changes**.
    ///
    /// * `access_token` — actually the **App Key** (client_id)
    /// * `secret`       — actually the **App Secret** (client_secret)
    /// * `_webhook_port` — ignored; kept for API compatibility
    pub fn new(access_token: String, secret: String, _webhook_port: u16) -> Self {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        Self {
            app_key: Zeroizing::new(access_token),
            app_secret: Zeroizing::new(secret),
            client: reqwest::Client::new(),
            token_cache: Arc::new(Mutex::new(None)),
            webhook_cache: Arc::new(DashMap::new()),
            shutdown_tx: Arc::new(shutdown_tx),
            shutdown_rx,
        }
    }

    // ── Stream helpers ──────────────────────────────────────────────

    /// Call the gateway to obtain a one-time WebSocket endpoint + ticket.
    async fn open_connection(
        client: &reqwest::Client,
        app_key: &str,
        app_secret: &str,
    ) -> Result<(String, String), Box<dyn std::error::Error + Send + Sync>> {
        let body = serde_json::json!({
            "clientId": app_key,
            "clientSecret": app_secret,
            "subscriptions": [
                { "type": "EVENT", "topic": "*" },
                { "type": "CALLBACK", "topic": "/v1.0/im/bot/messages/get" }
            ],
            "ua": "openfang-dingtalk/1.0"
        });

        let resp = client
            .post(STREAM_OPEN_URL)
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(format!("DingTalk open_connection failed ({status}): {text}").into());
        }

        let data: serde_json::Value = resp.json().await?;
        info!("DingTalk: open_connection response: {}", data);
        let endpoint = data["endpoint"]
            .as_str()
            .ok_or("missing endpoint in response")?
            .to_string();
        let ticket = data["ticket"]
            .as_str()
            .ok_or("missing ticket in response")?
            .to_string();

        Ok((endpoint, ticket))
    }

    /// Get (or refresh) the OAuth2 access token for sending messages.
    async fn get_access_token(
        client: &reqwest::Client,
        app_key: &str,
        app_secret: &str,
        cache: &Arc<Mutex<Option<(String, i64)>>>,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let now = Utc::now().timestamp();
        {
            let guard = cache.lock().await;
            if let Some((ref token, expiry)) = *guard {
                // Refresh 5 minutes before expiry
                if now < expiry - 300 {
                    return Ok(token.clone());
                }
            }
        }

        let body = serde_json::json!({
            "appKey": app_key,
            "appSecret": app_secret,
        });
        let resp = client.post(TOKEN_URL).json(&body).send().await?;
        let data: serde_json::Value = resp.json().await?;
        let token = data["accessToken"]
            .as_str()
            .ok_or("missing accessToken")?
            .to_string();
        let expire_in = data["expireIn"].as_i64().unwrap_or(7200);

        let mut guard = cache.lock().await;
        *guard = Some((token.clone(), now + expire_in));
        Ok(token)
    }

    /// Parse incoming Stream CALLBACK data into message fields.
    #[allow(clippy::type_complexity)]
    fn parse_stream_message(
        data: &serde_json::Value,
    ) -> Option<(String, String, String, String, String, bool, Option<String>)> {
        // data is the parsed JSON from the "data" field (which is a JSON string)
        let msg_type = data["msgtype"].as_str()?;
        let text = match msg_type {
            "text" => data["text"]["content"].as_str()?.trim().to_string(),
            _ => return None,
        };
        if text.is_empty() {
            return None;
        }

        let sender_id = data["senderId"].as_str().unwrap_or("unknown").to_string();
        let sender_nick = data["senderNick"]
            .as_str()
            .unwrap_or("Unknown")
            .to_string();
        let conversation_id = data["conversationId"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let is_group = data["conversationType"].as_str() == Some("2");
        let session_webhook = data["sessionWebhook"].as_str().map(|s| s.to_string());
        // robotCode is needed for some reply modes
        let sender_staff_id = data["senderStaffId"]
            .as_str()
            .unwrap_or(&sender_id)
            .to_string();

        Some((
            text,
            sender_id,
            sender_nick,
            conversation_id,
            sender_staff_id,
            is_group,
            session_webhook,
        ))
    }

    /// Send a reply via sessionWebhook (preferred — matches CoPaw behaviour).
    ///
    /// DingTalk may return HTTP 200 even on errors, so we must inspect `errcode`
    /// in the JSON response body.
    async fn reply_via_webhook(
        client: &reqwest::Client,
        webhook_url: &str,
        text: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Always use text type (matches CoPaw behaviour).
        // Markdown title shows in conversation list preview instead of content.
        let body = serde_json::json!({
            "msgtype": "text",
            "text": { "content": text }
        });

        let resp = client.post(webhook_url).json(&body).send().await?;
        let status = resp.status();
        let resp_text = resp.text().await.unwrap_or_default();

        if !status.is_success() {
            return Err(format!("DingTalk webhook reply failed ({status}): {resp_text}").into());
        }

        // DingTalk returns HTTP 200 even on errors — check errcode in body
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&resp_text) {
            let errcode = json["errcode"].as_i64().unwrap_or(0);
            if errcode != 0 {
                let errmsg = json["errmsg"].as_str().unwrap_or("");
                return Err(
                    format!("DingTalk API error: errcode={errcode} errmsg={errmsg}").into(),
                );
            }
        }

        Ok(())
    }

    /// Send a reply via OpenAPI batch send (fallback when no sessionWebhook).
    async fn reply_via_openapi(
        client: &reqwest::Client,
        access_token: &str,
        robot_code: &str,
        user_ids: &[&str],
        text: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let body = serde_json::json!({
            "robotCode": robot_code,
            "userIds": user_ids,
            "msgKey": "sampleText",
            "msgParam": serde_json::json!({ "content": text }).to_string(),
        });

        let resp = client
            .post(REPLY_URL)
            .header("x-acs-dingtalk-access-token", access_token)
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let err = resp.text().await.unwrap_or_default();
            warn!("DingTalk OpenAPI reply failed ({status}): {err}");
        }
        Ok(())
    }
}

#[async_trait]
impl ChannelAdapter for DingTalkAdapter {
    fn name(&self) -> &str {
        "dingtalk"
    }

    fn channel_type(&self) -> ChannelType {
        ChannelType::Custom("dingtalk".to_string())
    }

    async fn start(
        &self,
    ) -> Result<Pin<Box<dyn Stream<Item = ChannelMessage> + Send>>, Box<dyn std::error::Error>>
    {
        let (tx, rx) = mpsc::channel::<ChannelMessage>(256);
        let app_key = self.app_key.clone();
        let app_secret = self.app_secret.clone();
        let client = self.client.clone();
        let _token_cache = self.token_cache.clone();
        let webhook_cache = self.webhook_cache.clone();
        let mut shutdown_rx = self.shutdown_rx.clone();

        info!("DingTalk adapter starting in Stream mode (no webhook server needed)");

        tokio::spawn(async move {
            let mut backoff = RECONNECT_BASE;

            loop {
                // Check shutdown before each connection attempt
                if *shutdown_rx.borrow() {
                    break;
                }

                // ── Step 1: obtain WebSocket endpoint ──
                let (endpoint, ticket) = match Self::open_connection(
                    &client,
                    app_key.as_str(),
                    app_secret.as_str(),
                )
                .await
                {
                    Ok(v) => v,
                    Err(e) => {
                        error!("DingTalk: failed to open connection: {e}");
                        tokio::select! {
                            _ = tokio::time::sleep(backoff) => {}
                            _ = shutdown_rx.changed() => { break; }
                        }
                        backoff = (backoff * 2).min(RECONNECT_MAX);
                        continue;
                    }
                };

                // ── Step 2: connect WebSocket ──
                let encoded_ticket = url::form_urlencoded::Serializer::new(String::new())
                    .append_pair("ticket", &ticket)
                    .finish();
                let ws_url = format!("{}?{}", endpoint, encoded_ticket);
                info!("DingTalk: connecting to {}", endpoint);

                let ws_stream = match tokio_tungstenite::connect_async(&ws_url).await {
                    Ok((stream, _)) => stream,
                    Err(e) => {
                        error!("DingTalk: WebSocket connect failed: {e}");
                        tokio::select! {
                            _ = tokio::time::sleep(backoff) => {}
                            _ = shutdown_rx.changed() => { break; }
                        }
                        backoff = (backoff * 2).min(RECONNECT_MAX);
                        continue;
                    }
                };

                info!("DingTalk: Stream connected");
                backoff = RECONNECT_BASE; // Reset backoff on success

                let (mut ws_sink, mut ws_source) = ws_stream.split();
                let mut heartbeat =
                    tokio::time::interval(HEARTBEAT_INTERVAL);
                heartbeat.tick().await; // Skip the immediate first tick

                // ── Step 3: message loop ──
                loop {
                    tokio::select! {
                        msg = ws_source.next() => {
                            let msg = match msg {
                                Some(Ok(m)) => m,
                                Some(Err(e)) => {
                                    warn!("DingTalk: WebSocket error: {e}");
                                    break; // Will reconnect
                                }
                                None => {
                                    info!("DingTalk: WebSocket stream ended");
                                    break; // Will reconnect
                                }
                            };

                            debug!("DingTalk: received WS frame: {:?}", msg);

                            // Only process text frames
                            let text = match msg {
                                tokio_tungstenite::tungstenite::Message::Text(t) => t,
                                tokio_tungstenite::tungstenite::Message::Ping(data) => {
                                    let _ = ws_sink.send(
                                        tokio_tungstenite::tungstenite::Message::Pong(data)
                                    ).await;
                                    continue;
                                }
                                tokio_tungstenite::tungstenite::Message::Close(_) => {
                                    info!("DingTalk: received close frame");
                                    break;
                                }
                                _ => continue,
                            };

                            // Parse the Stream frame
                            let frame: serde_json::Value = match serde_json::from_str(&text) {
                                Ok(v) => v,
                                Err(e) => {
                                    warn!("DingTalk: invalid JSON frame: {e}");
                                    continue;
                                }
                            };

                            let frame_type = frame["type"].as_str().unwrap_or("");
                            let headers = &frame["headers"];
                            let message_id = headers["messageId"]
                                .as_str()
                                .unwrap_or("")
                                .to_string();

                            match frame_type {
                                "SYSTEM" => {
                                    // Handle system messages: ping, disconnect, etc.
                                    let topic = headers["topic"].as_str().unwrap_or("");
                                    match topic {
                                        "ping" => {
                                            // Echo the data back as pong
                                            let ack = serde_json::json!({
                                                "code": 200,
                                                "headers": {
                                                    "contentType": "application/json",
                                                    "messageId": message_id,
                                                },
                                                "message": "OK",
                                                "data": frame["data"].as_str().unwrap_or(""),
                                            });
                                            let _ = ws_sink.send(
                                                tokio_tungstenite::tungstenite::Message::Text(
                                                    ack.to_string()
                                                )
                                            ).await;
                                        }
                                        "disconnect" => {
                                            info!("DingTalk: server requested disconnect");
                                            break; // Will reconnect
                                        }
                                        _ => {
                                            debug!("DingTalk: system message: {topic}");
                                        }
                                    }
                                }
                                "CALLBACK" => {
                                    // Parse the embedded message data
                                    let data_str = frame["data"].as_str().unwrap_or("{}");
                                    let data: serde_json::Value =
                                        serde_json::from_str(data_str).unwrap_or_default();

                                    if let Some((
                                        msg_text,
                                        sender_id,
                                        sender_nick,
                                        conv_id,
                                        staff_id,
                                        is_group,
                                        session_webhook,
                                    )) = Self::parse_stream_message(&data)
                                    {
                                        // Strip @mention prefix in group messages
                                        // (CoPaw: messageText.replace(/^@\S+\s*/, ""))
                                        let clean_text = if is_group {
                                            let t = msg_text.trim_start();
                                            if t.starts_with('@') {
                                                // Remove the @mention and any trailing whitespace
                                                t.split_once(char::is_whitespace)
                                                    .map(|(_, rest)| rest)
                                                    .unwrap_or("")
                                                    .trim()
                                                    .to_string()
                                            } else {
                                                msg_text
                                            }
                                        } else {
                                            msg_text
                                        };

                                        if clean_text.is_empty() {
                                            // After stripping @mention, nothing left
                                            // Still ACK below
                                        } else {
                                            let content = if clean_text.starts_with('/') {
                                                let parts: Vec<&str> =
                                                    clean_text.splitn(2, ' ').collect();
                                                let cmd =
                                                    parts[0].trim_start_matches('/');
                                                let args: Vec<String> = parts
                                                    .get(1)
                                                    .map(|a| {
                                                        a.split_whitespace()
                                                            .map(String::from)
                                                            .collect()
                                                    })
                                                    .unwrap_or_default();
                                                ChannelContent::Command {
                                                    name: cmd.to_string(),
                                                    args,
                                                }
                                            } else {
                                                ChannelContent::Text(clean_text)
                                            };

                                            // Cache sessionWebhook for send() to use
                                            let webhook_expiry = data["sessionWebhookExpiredTime"]
                                                .as_i64()
                                                .unwrap_or(0);
                                            if let Some(ref sw) = session_webhook {
                                                webhook_cache.insert(
                                                    staff_id.clone(),
                                                    (sw.clone(), webhook_expiry),
                                                );
                                            }

                                            let mut metadata = HashMap::new();
                                            metadata.insert(
                                                "conversation_id".to_string(),
                                                serde_json::Value::String(conv_id),
                                            );
                                            metadata.insert(
                                                "sender_id".to_string(),
                                                serde_json::Value::String(sender_id),
                                            );
                                            metadata.insert(
                                                "sender_staff_id".to_string(),
                                                serde_json::Value::String(
                                                    staff_id.clone(),
                                                ),
                                            );
                                            if let Some(ref sw) = session_webhook {
                                                metadata.insert(
                                                    "session_webhook".to_string(),
                                                    serde_json::Value::String(sw.clone()),
                                                );
                                            }
                                            if let Some(rc) = data["robotCode"].as_str() {
                                                metadata.insert(
                                                    "robot_code".to_string(),
                                                    serde_json::Value::String(
                                                        rc.to_string(),
                                                    ),
                                                );
                                            }

                                            // Use staff_id as platform_id so send()
                                            // can look up the cached webhook and also
                                            // use it as a valid userIds for OpenAPI fallback
                                            let channel_msg = ChannelMessage {
                                                channel: ChannelType::Custom(
                                                    "dingtalk".to_string(),
                                                ),
                                                platform_message_id: format!(
                                                    "dt-{}",
                                                    Utc::now().timestamp_millis()
                                                ),
                                                sender: ChannelUser {
                                                    platform_id: staff_id,
                                                    display_name: sender_nick,
                                                    openfang_user: None,
                                                },
                                                content,
                                                target_agent: None,
                                                timestamp: Utc::now(),
                                                is_group,
                                                thread_id: None,
                                                metadata,
                                            };

                                            let _ = tx.send(channel_msg).await;
                                        }
                                    }

                                    // ACK the callback
                                    let ack = serde_json::json!({
                                        "code": 200,
                                        "headers": {
                                            "contentType": "application/json",
                                            "messageId": message_id,
                                        },
                                        "message": "OK",
                                        "data": "{}",
                                    });
                                    let _ = ws_sink.send(
                                        tokio_tungstenite::tungstenite::Message::Text(
                                            ack.to_string()
                                        )
                                    ).await;
                                }
                                "EVENT" => {
                                    // ACK events but don't process them
                                    let ack = serde_json::json!({
                                        "code": 200,
                                        "headers": {
                                            "contentType": "application/json",
                                            "messageId": message_id,
                                        },
                                        "message": "OK",
                                        "data": "{}",
                                    });
                                    let _ = ws_sink.send(
                                        tokio_tungstenite::tungstenite::Message::Text(
                                            ack.to_string()
                                        )
                                    ).await;
                                }
                                _ => {
                                    debug!("DingTalk: unknown frame type: {frame_type}");
                                }
                            }
                        }

                        _ = heartbeat.tick() => {
                            // Send WebSocket-level ping for keepalive
                            if ws_sink
                                .send(tokio_tungstenite::tungstenite::Message::Ping(vec![]))
                                .await
                                .is_err()
                            {
                                warn!("DingTalk: heartbeat ping failed, reconnecting");
                                break;
                            }
                        }

                        _ = shutdown_rx.changed() => {
                            info!("DingTalk adapter shutting down");
                            let _ = ws_sink.send(
                                tokio_tungstenite::tungstenite::Message::Close(None)
                            ).await;
                            return; // Exit the task entirely
                        }
                    }
                }

                // Reconnect after a brief delay
                info!("DingTalk: reconnecting in {:?}...", backoff);
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = shutdown_rx.changed() => { break; }
                }
            }

            info!("DingTalk Stream adapter stopped");
        });

        Ok(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx)))
    }

    async fn send(
        &self,
        user: &ChannelUser,
        content: ChannelContent,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let text = match content {
            ChannelContent::Text(t) => t,
            _ => "(Unsupported content type)".to_string(),
        };

        let chunks = split_message(&text, MAX_MESSAGE_LEN);
        let num_chunks = chunks.len();

        // Look up cached sessionWebhook for this user (keyed by staff_id = platform_id)
        let cached_webhook = self.webhook_cache.get(&user.platform_id).map(|e| {
            let (url, expiry) = e.value().clone();
            (url, expiry)
        });

        for chunk in &chunks {
            // Strategy 1: sessionWebhook (preferred — matches CoPaw behaviour)
            if let Some((ref webhook_url, expiry)) = cached_webhook {
                let now_ms = Utc::now().timestamp_millis();
                if expiry == 0 || now_ms < expiry {
                    match Self::reply_via_webhook(&self.client, webhook_url, chunk).await {
                        Ok(()) => {
                            debug!("DingTalk: replied via sessionWebhook to {}", user.display_name);
                            if num_chunks > 1 {
                                tokio::time::sleep(Duration::from_millis(200)).await;
                            }
                            continue;
                        }
                        Err(e) => {
                            warn!("DingTalk: sessionWebhook failed, trying OpenAPI: {e}");
                            // Fall through to OpenAPI
                        }
                    }
                } else {
                    warn!(
                        "DingTalk: sessionWebhook expired for {}, falling back to OpenAPI",
                        user.display_name
                    );
                }
            }

            // Strategy 2: OpenAPI batch send (fallback — uses staff_id as userIds)
            let token = Self::get_access_token(
                &self.client,
                self.app_key.as_str(),
                self.app_secret.as_str(),
                &self.token_cache,
            )
            .await
            .map_err(|e| -> Box<dyn std::error::Error> {
                format!("DingTalk: failed to get access token: {e}").into()
            })?;

            Self::reply_via_openapi(
                &self.client,
                &token,
                self.app_key.as_str(),
                &[&user.platform_id],
                chunk,
            )
            .await
            .map_err(|e| -> Box<dyn std::error::Error> {
                format!("DingTalk: reply failed: {e}").into()
            })?;

            if num_chunks > 1 {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }

        Ok(())
    }

    async fn send_typing(&self, _user: &ChannelUser) -> Result<(), Box<dyn std::error::Error>> {
        // DingTalk does not support typing indicators.
        Ok(())
    }

    async fn stop(&self) -> Result<(), Box<dyn std::error::Error>> {
        let _ = self.shutdown_tx.send(true);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dingtalk_adapter_creation() {
        let adapter =
            DingTalkAdapter::new("test-app-key".to_string(), "test-app-secret".to_string(), 8080);
        assert_eq!(adapter.name(), "dingtalk");
        assert_eq!(
            adapter.channel_type(),
            ChannelType::Custom("dingtalk".to_string())
        );
    }

    #[test]
    fn test_parse_stream_message_text() {
        let data = serde_json::json!({
            "msgtype": "text",
            "text": { "content": "Hello bot" },
            "senderId": "user123",
            "senderNick": "Alice",
            "senderStaffId": "staff456",
            "conversationId": "conv789",
            "conversationType": "2",
            "sessionWebhook": "https://oapi.dingtalk.com/robot/sendBySession?session=abc",
            "robotCode": "dingo123",
        });
        let result = DingTalkAdapter::parse_stream_message(&data);
        assert!(result.is_some());
        let (text, sender_id, sender_nick, conv_id, staff_id, is_group, sw) = result.unwrap();
        assert_eq!(text, "Hello bot");
        assert_eq!(sender_id, "user123");
        assert_eq!(sender_nick, "Alice");
        assert_eq!(conv_id, "conv789");
        assert_eq!(staff_id, "staff456");
        assert!(is_group);
        assert!(sw.is_some());
    }

    #[test]
    fn test_parse_stream_message_dm() {
        let data = serde_json::json!({
            "msgtype": "text",
            "text": { "content": "DM message" },
            "senderId": "u1",
            "senderNick": "Bob",
            "conversationId": "c1",
            "conversationType": "1",
        });
        let result = DingTalkAdapter::parse_stream_message(&data);
        assert!(result.is_some());
        let (_, _, _, _, _, is_group, sw) = result.unwrap();
        assert!(!is_group);
        assert!(sw.is_none());
    }

    #[test]
    fn test_parse_stream_message_unsupported_type() {
        let data = serde_json::json!({
            "msgtype": "image",
            "image": { "downloadCode": "abc" },
        });
        assert!(DingTalkAdapter::parse_stream_message(&data).is_none());
    }

    #[test]
    fn test_parse_stream_message_empty_text() {
        let data = serde_json::json!({
            "msgtype": "text",
            "text": { "content": "  " },
            "senderId": "u1",
            "senderNick": "Bob",
            "conversationId": "c1",
            "conversationType": "1",
        });
        assert!(DingTalkAdapter::parse_stream_message(&data).is_none());
    }
}
