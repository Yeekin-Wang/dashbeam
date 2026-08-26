use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}

impl BridgeError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new("invalid_request", message)
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new("unsupported", message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new("internal", message)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorResponse {
    pub ok: bool,
    pub error: BridgeError,
}

pub fn error_json(error: BridgeError) -> String {
    serde_json::to_string(&ErrorResponse { ok: false, error })
        .unwrap_or_else(|_| {
            "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize error response\"}}".to_string()
        })
}
