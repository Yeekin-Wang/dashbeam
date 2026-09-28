use crate::error::BridgeError;
use protocol::{
    build_discovery_mode, build_relay_mode, normalize_display_name, AddrInfoOptions,
    Discoverability, DiscoveryConfigArg, DiscoveryModeOption, FileMetadata, ReceiveOptions,
    RelayConfigArg, RelayModeOption, SendOptions,
};
use serde::Deserialize;
use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeStartRequest {
    pub session_id: String,
    pub data_dir: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub device_type: Option<String>,
    pub discoverability: String,
    #[serde(default)]
    pub relay_mode: Option<String>,
    #[serde(default)]
    pub relay_urls: Option<Vec<String>>,
    #[serde(default)]
    pub relay_auth_token: Option<String>,
    #[serde(default)]
    pub discovery_mode: Option<Value>,
}

#[derive(Debug)]
pub struct ValidatedNodeStart {
    pub session_id: String,
    pub data_dir: PathBuf,
    pub display_name: Option<String>,
    pub device_type: Option<String>,
    pub discoverability: Discoverability,
    pub relay_mode: RelayModeOption,
    pub discovery_mode: DiscoveryModeOption,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeCommandRequest {
    pub session_id: String,
    pub operation: String,
    #[serde(default)]
    pub ttl_secs: Option<u64>,
    #[serde(default)]
    pub ticket: Option<String>,
    #[serde(default)]
    pub endpoint_id: Option<String>,
    #[serde(default)]
    pub accept: Option<bool>,
    #[serde(default)]
    pub block: Option<bool>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub discoverability: Option<String>,
    #[serde(default)]
    pub blob_ticket: Option<String>,
    #[serde(default)]
    pub file_count: Option<u32>,
    #[serde(default)]
    pub total_size: Option<u64>,
}

#[derive(Debug)]
pub struct ValidatedNodeCommand {
    pub session_id: String,
    pub command: NodeCommand,
}

#[derive(Debug)]
pub enum NodeCommand {
    GetDeviceInfo,
    ListPaired,
    ListNearby,
    StartPairingHost {
        ttl_secs: Option<u64>,
    },
    StopPairingHost,
    JoinPairing {
        ticket: String,
    },
    ForgetPaired {
        endpoint_id: String,
    },
    RequestNearbyPair {
        endpoint_id: String,
    },
    RespondNearbyInvite {
        endpoint_id: String,
        accept: bool,
        block: bool,
    },
    RenameDevice {
        display_name: String,
    },
    RenamePaired {
        endpoint_id: String,
        display_name: String,
    },
    SetDiscoverability {
        discoverability: Discoverability,
    },
    InvitePaired {
        endpoint_id: String,
        blob_ticket: String,
        file_count: u32,
        total_size: u64,
    },
    InviteNearby {
        endpoint_id: String,
        blob_ticket: String,
        file_count: u32,
        total_size: u64,
    },
    RespondPairedInvite {
        endpoint_id: String,
        accept: bool,
    },
}

impl NodeCommand {
    pub fn operation(&self) -> &'static str {
        match self {
            Self::GetDeviceInfo => "getDeviceInfo",
            Self::ListPaired => "listPaired",
            Self::ListNearby => "listNearby",
            Self::StartPairingHost { .. } => "startPairingHost",
            Self::StopPairingHost => "stopPairingHost",
            Self::JoinPairing { .. } => "joinPairing",
            Self::ForgetPaired { .. } => "forgetPaired",
            Self::RequestNearbyPair { .. } => "requestNearbyPair",
            Self::RespondNearbyInvite { .. } => "respondNearbyInvite",
            Self::RenameDevice { .. } => "renameDevice",
            Self::RenamePaired { .. } => "renamePaired",
            Self::SetDiscoverability { .. } => "setDiscoverability",
            Self::InvitePaired { .. } => "invitePaired",
            Self::InviteNearby { .. } => "inviteNearby",
            Self::RespondPairedInvite { .. } => "respondPairedInvite",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareRequest {
    pub session_id: String,
    pub paths: Vec<String>,
    #[serde(default)]
    pub metadata: Option<FileMetadata>,
    #[serde(default)]
    pub relay_mode: Option<String>,
    #[serde(default)]
    pub ticket_type: Option<String>,
    #[serde(default)]
    pub discovery_mode: Option<Value>,
    #[serde(default)]
    pub relay_urls: Option<Vec<String>>,
    #[serde(default)]
    pub relay_auth_token: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceiveRequest {
    pub session_id: String,
    pub ticket: String,
    pub output_dir: String,
    #[serde(default)]
    pub relay_mode: Option<String>,
    #[serde(default)]
    pub discovery_mode: Option<Value>,
    #[serde(default)]
    pub relay_urls: Option<Vec<String>>,
    #[serde(default)]
    pub relay_auth_token: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataRequest {
    pub session_id: String,
    pub ticket: String,
    #[serde(default)]
    pub relay_mode: Option<String>,
    #[serde(default)]
    pub discovery_mode: Option<Value>,
    #[serde(default)]
    pub relay_urls: Option<Vec<String>>,
    #[serde(default)]
    pub relay_auth_token: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRequest {
    pub session_id: String,
}

pub fn parse_request<T: for<'de> Deserialize<'de>>(json: &str) -> Result<T, BridgeError> {
    serde_json::from_str(json)
        .map_err(|e| BridgeError::invalid_request(format!("invalid JSON request: {e}")))
}

fn parse_network_modes(
    relay_mode: Option<&str>,
    relay_urls: Option<Vec<String>>,
    relay_auth_token: Option<String>,
    discovery_mode: Option<Value>,
) -> Result<(RelayModeOption, DiscoveryModeOption), BridgeError> {
    let mode = relay_mode.unwrap_or("default");
    if mode != "custom"
        && (relay_urls.as_ref().is_some_and(|urls| !urls.is_empty())
            || relay_auth_token
                .as_ref()
                .is_some_and(|token| !token.is_empty()))
    {
        return Err(BridgeError::invalid_request(
            "custom relay fields require relayMode custom",
        ));
    }
    let relay = build_relay_mode(Some(RelayConfigArg {
        mode: mode.to_string(),
        urls: relay_urls.unwrap_or_default(),
        auth_token: relay_auth_token,
        fallback: None,
    }))
    .map_err(BridgeError::invalid_request)?;
    let discovery = match discovery_mode {
        None | Some(Value::Null) => DiscoveryModeOption::Default,
        Some(Value::String(mode)) if mode == "default" => DiscoveryModeOption::Default,
        Some(value) => {
            let config: DiscoveryConfigArg = serde_json::from_value(value).map_err(|error| {
                BridgeError::invalid_request(format!("invalid discoveryMode: {error}"))
            })?;
            build_discovery_mode(Some(config)).map_err(BridgeError::invalid_request)?
        }
    };
    Ok((relay, discovery))
}

fn parse_ticket_type(value: Option<&str>) -> Result<AddrInfoOptions, BridgeError> {
    match value.unwrap_or("id") {
        "id" => Ok(AddrInfoOptions::Id),
        "relayAndAddresses" => Ok(AddrInfoOptions::RelayAndAddresses),
        "relay" => Ok(AddrInfoOptions::Relay),
        "addresses" => Ok(AddrInfoOptions::Addresses),
        other => Err(BridgeError::invalid_request(format!(
            "invalid ticketType: {other}"
        ))),
    }
}

fn validate_session_id(session_id: &str) -> Result<(), BridgeError> {
    if session_id.trim().is_empty() {
        return Err(BridgeError::invalid_request("sessionId is required"));
    }
    Ok(())
}

fn required_string(value: Option<String>, field: &str) -> Result<String, BridgeError> {
    let value =
        value.ok_or_else(|| BridgeError::invalid_request(format!("{field} is required")))?;
    if value.trim().is_empty() {
        return Err(BridgeError::invalid_request(format!(
            "{field} must not be empty"
        )));
    }
    Ok(value)
}

pub fn parse_discoverability(value: &str) -> Result<Discoverability, BridgeError> {
    match value {
        "everyone" => Ok(Discoverability::Everyone),
        "paired-only" => Ok(Discoverability::PairedOnly),
        "off" => Ok(Discoverability::Off),
        other => Err(BridgeError::invalid_request(format!(
            "invalid discoverability: {other}"
        ))),
    }
}

fn validate_device_type(device_type: String) -> Result<String, BridgeError> {
    match device_type.as_str() {
        "phone" | "tablet" | "foldable" | "widefold" | "triplefold" | "2in1" | "unknown" => {
            Ok(device_type)
        }
        other => Err(BridgeError::invalid_request(format!(
            "invalid deviceType: {other}"
        ))),
    }
}

fn validate_real_path(path: &str) -> Result<(), BridgeError> {
    if path.trim().is_empty() {
        return Err(BridgeError::invalid_request("path must not be empty"));
    }
    if path.to_ascii_lowercase().starts_with("file://") {
        return Err(BridgeError::invalid_request(
            "path must be a real sandbox filesystem path, not a file:// URI",
        ));
    }
    Ok(())
}

impl NodeStartRequest {
    pub fn validate(self) -> Result<ValidatedNodeStart, BridgeError> {
        validate_session_id(&self.session_id)?;
        validate_real_path(&self.data_dir)?;
        if !Path::new(&self.data_dir).is_absolute() {
            return Err(BridgeError::invalid_request(
                "dataDir must be an absolute sandbox filesystem path",
            ));
        }

        let display_name = self
            .display_name
            .map(|name| normalize_display_name(&name).map_err(BridgeError::invalid_request))
            .transpose()?;
        let device_type = self.device_type.map(validate_device_type).transpose()?;
        let (relay_mode, discovery_mode) = parse_network_modes(
            self.relay_mode.as_deref(),
            self.relay_urls,
            self.relay_auth_token,
            self.discovery_mode,
        )?;

        Ok(ValidatedNodeStart {
            session_id: self.session_id,
            data_dir: PathBuf::from(self.data_dir),
            display_name,
            device_type,
            discoverability: parse_discoverability(&self.discoverability)?,
            relay_mode,
            discovery_mode,
        })
    }
}

impl NodeCommandRequest {
    pub fn validate(self) -> Result<ValidatedNodeCommand, BridgeError> {
        validate_session_id(&self.session_id)?;

        let command = match self.operation.as_str() {
            "getDeviceInfo" => NodeCommand::GetDeviceInfo,
            "listPaired" => NodeCommand::ListPaired,
            "listNearby" => NodeCommand::ListNearby,
            "startPairingHost" => NodeCommand::StartPairingHost {
                ttl_secs: self.ttl_secs,
            },
            "stopPairingHost" => NodeCommand::StopPairingHost,
            "joinPairing" => NodeCommand::JoinPairing {
                ticket: required_string(self.ticket, "ticket")?,
            },
            "forgetPaired" => NodeCommand::ForgetPaired {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
            },
            "requestNearbyPair" => NodeCommand::RequestNearbyPair {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
            },
            "respondNearbyInvite" => NodeCommand::RespondNearbyInvite {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
                accept: self
                    .accept
                    .ok_or_else(|| BridgeError::invalid_request("accept is required"))?,
                block: self
                    .block
                    .ok_or_else(|| BridgeError::invalid_request("block is required"))?,
            },
            "renameDevice" => NodeCommand::RenameDevice {
                display_name: normalize_display_name(&required_string(
                    self.display_name,
                    "displayName",
                )?)
                .map_err(BridgeError::invalid_request)?,
            },
            "renamePaired" => NodeCommand::RenamePaired {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
                display_name: normalize_display_name(&required_string(
                    self.display_name,
                    "displayName",
                )?)
                .map_err(BridgeError::invalid_request)?,
            },
            "setDiscoverability" => NodeCommand::SetDiscoverability {
                discoverability: parse_discoverability(&required_string(
                    self.discoverability,
                    "discoverability",
                )?)?,
            },
            "invitePaired" => NodeCommand::InvitePaired {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
                blob_ticket: required_string(self.blob_ticket, "blobTicket")?,
                file_count: self
                    .file_count
                    .ok_or_else(|| BridgeError::invalid_request("fileCount is required"))?,
                total_size: self
                    .total_size
                    .ok_or_else(|| BridgeError::invalid_request("totalSize is required"))?,
            },
            "inviteNearby" => NodeCommand::InviteNearby {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
                blob_ticket: required_string(self.blob_ticket, "blobTicket")?,
                file_count: self
                    .file_count
                    .ok_or_else(|| BridgeError::invalid_request("fileCount is required"))?,
                total_size: self
                    .total_size
                    .ok_or_else(|| BridgeError::invalid_request("totalSize is required"))?,
            },
            "respondPairedInvite" => NodeCommand::RespondPairedInvite {
                endpoint_id: required_string(self.endpoint_id, "endpointId")?,
                accept: self
                    .accept
                    .ok_or_else(|| BridgeError::invalid_request("accept is required"))?,
            },
            "" => return Err(BridgeError::invalid_request("operation is required")),
            other => {
                return Err(BridgeError::invalid_request(format!(
                    "unsupported node operation: {other}"
                )))
            }
        };

        Ok(ValidatedNodeCommand {
            session_id: self.session_id,
            command,
        })
    }
}

impl ShareRequest {
    pub fn validate(
        self,
    ) -> Result<(String, Vec<PathBuf>, Option<FileMetadata>, SendOptions), BridgeError> {
        validate_session_id(&self.session_id)?;
        if self.paths.is_empty() {
            return Err(BridgeError::invalid_request("paths must not be empty"));
        }

        let (relay_mode, discovery_mode) = parse_network_modes(
            self.relay_mode.as_deref(),
            self.relay_urls,
            self.relay_auth_token,
            self.discovery_mode,
        )?;

        let mut parsed_paths = Vec::with_capacity(self.paths.len());
        for path in self.paths {
            validate_real_path(&path)?;
            parsed_paths.push(PathBuf::from(path));
        }

        let send_options = SendOptions {
            relay_mode,
            discovery_mode,
            ticket_type: parse_ticket_type(self.ticket_type.as_deref())?,
            magic_ipv4_addr: None,
            magic_ipv6_addr: None,
        };

        Ok((self.session_id, parsed_paths, self.metadata, send_options))
    }
}

impl ReceiveRequest {
    pub fn validate(self) -> Result<(String, String, ReceiveOptions), BridgeError> {
        validate_session_id(&self.session_id)?;
        if self.ticket.trim().is_empty() {
            return Err(BridgeError::invalid_request("ticket is required"));
        }
        validate_real_path(&self.output_dir)?;

        let (relay_mode, discovery_mode) = parse_network_modes(
            self.relay_mode.as_deref(),
            self.relay_urls,
            self.relay_auth_token,
            self.discovery_mode,
        )?;

        let options = ReceiveOptions {
            output_dir: Some(PathBuf::from(self.output_dir)),
            relay_mode,
            discovery_mode,
            magic_ipv4_addr: None,
            magic_ipv6_addr: None,
        };

        Ok((self.session_id, self.ticket, options))
    }
}

impl MetadataRequest {
    pub fn validate(self) -> Result<(String, String, ReceiveOptions), BridgeError> {
        validate_session_id(&self.session_id)?;
        if self.ticket.trim().is_empty() {
            return Err(BridgeError::invalid_request("ticket is required"));
        }

        let (relay_mode, discovery_mode) = parse_network_modes(
            self.relay_mode.as_deref(),
            self.relay_urls,
            self.relay_auth_token,
            self.discovery_mode,
        )?;

        let options = ReceiveOptions {
            output_dir: None,
            relay_mode,
            discovery_mode,
            magic_ipv4_addr: None,
            magic_ipv6_addr: None,
        };

        Ok((self.session_id, self.ticket, options))
    }
}

impl SessionRequest {
    pub fn validate(self) -> Result<String, BridgeError> {
        validate_session_id(&self.session_id)?;
        Ok(self.session_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn absolute_data_dir() -> &'static str {
        if cfg!(windows) {
            "C:/dashbeam/data"
        } else {
            "/data/storage/el2/base/files/dashbeam"
        }
    }

    #[test]
    fn node_start_request_accepts_supported_profile() {
        let request: NodeStartRequest = parse_request(
            &serde_json::json!({
                "sessionId": "node-1",
                "dataDir": absolute_data_dir(),
                "displayName": "  My Phone  ",
                "deviceType": "phone",
                "discoverability": "paired-only"
            })
            .to_string(),
        )
        .expect("parse node request");

        let validated = request.validate().expect("validate node request");
        assert_eq!(validated.session_id, "node-1");
        assert_eq!(validated.display_name.as_deref(), Some("My Phone"));
        assert_eq!(validated.device_type.as_deref(), Some("phone"));
        assert_eq!(validated.discoverability, Discoverability::PairedOnly);
        assert!(matches!(validated.relay_mode, RelayModeOption::Default));
        assert!(matches!(
            validated.discovery_mode,
            DiscoveryModeOption::Default
        ));
    }

    #[test]
    fn node_start_request_accepts_custom_network() {
        let request: NodeStartRequest = parse_request(
            &serde_json::json!({
                "sessionId": "node-custom",
                "dataDir": absolute_data_dir(),
                "discoverability": "everyone",
                "relayMode": "custom",
                "relayUrls": ["https://relay.example.com"],
                "discoveryMode": {
                    "mode": "custom",
                    "pkarr_relay_url": "https://dns.example.com/pkarr",
                    "dns_origin": "example.com"
                }
            })
            .to_string(),
        )
        .expect("parse custom node request");

        let validated = request.validate().expect("validate custom network");
        assert!(matches!(
            validated.relay_mode,
            RelayModeOption::Custom { .. }
        ));
        assert!(matches!(
            validated.discovery_mode,
            DiscoveryModeOption::Custom { .. }
        ));
    }

    #[test]
    fn network_modes_reject_invalid_custom_urls() {
        assert_eq!(
            parse_network_modes(
                Some("custom"),
                Some(vec!["http://relay.example.com".into()]),
                None,
                None
            )
            .expect_err("insecure relay")
            .code,
            "invalid_request"
        );
        assert_eq!(
            parse_network_modes(
                None,
                None,
                None,
                Some(serde_json::json!({
                    "mode": "custom", "pkarr_relay_url": "https://user@dns.example.com/pkarr"
                }))
            )
            .expect_err("credentialed discovery")
            .code,
            "invalid_request"
        );
    }

    #[test]
    fn transfer_requests_use_custom_network_settings() {
        let custom_network = serde_json::json!({
            "relayMode": "custom",
            "relayUrls": ["https://relay.example.com"],
            "discoveryMode": {
                "mode": "custom",
                "pkarr_relay_url": "https://dns.example.com/pkarr"
            }
        });
        let share: ShareRequest = parse_request(
            &serde_json::json!({
                "sessionId": "share-1",
                "paths": [absolute_data_dir()],
                "relayMode": custom_network["relayMode"],
                "relayUrls": custom_network["relayUrls"],
                "discoveryMode": custom_network["discoveryMode"]
            })
            .to_string(),
        )
        .expect("parse share");
        let (_, _, _, send) = share.validate().expect("validate share");
        assert!(matches!(send.relay_mode, RelayModeOption::Custom { .. }));
        assert!(matches!(
            send.discovery_mode,
            DiscoveryModeOption::Custom { .. }
        ));

        let receive: ReceiveRequest = parse_request(
            &serde_json::json!({
                "sessionId": "receive-1",
                "ticket": "ticket",
                "outputDir": absolute_data_dir(),
                "relayMode": custom_network["relayMode"],
                "relayUrls": custom_network["relayUrls"],
                "discoveryMode": custom_network["discoveryMode"]
            })
            .to_string(),
        )
        .expect("parse receive");
        let (_, _, options) = receive.validate().expect("validate receive");
        assert!(matches!(options.relay_mode, RelayModeOption::Custom { .. }));
        assert!(matches!(
            options.discovery_mode,
            DiscoveryModeOption::Custom { .. }
        ));

        let metadata: MetadataRequest = parse_request(
            &serde_json::json!({
                "sessionId": "metadata-1",
                "ticket": "ticket",
                "relayMode": custom_network["relayMode"],
                "relayUrls": custom_network["relayUrls"],
                "discoveryMode": custom_network["discoveryMode"]
            })
            .to_string(),
        )
        .expect("parse metadata");
        let (_, _, options) = metadata.validate().expect("validate metadata");
        assert!(matches!(options.relay_mode, RelayModeOption::Custom { .. }));
        assert!(matches!(
            options.discovery_mode,
            DiscoveryModeOption::Custom { .. }
        ));
    }

    #[test]
    fn node_start_request_rejects_non_filesystem_data_dir() {
        for data_dir in [
            "",
            "relative/path",
            "file:///data/storage/files",
            "FILE:///data/storage/files",
        ] {
            let request: NodeStartRequest = parse_request(
                &serde_json::json!({
                    "sessionId": "node-1",
                    "dataDir": data_dir,
                    "discoverability": "everyone"
                })
                .to_string(),
            )
            .expect("parse node request");

            assert_eq!(
                request.validate().expect_err("invalid dataDir").code,
                "invalid_request"
            );
        }
    }

    #[test]
    fn discoverability_parser_accepts_only_public_values() {
        assert_eq!(
            parse_discoverability("everyone").expect("everyone"),
            Discoverability::Everyone
        );
        assert_eq!(
            parse_discoverability("paired-only").expect("paired-only"),
            Discoverability::PairedOnly
        );
        assert_eq!(
            parse_discoverability("off").expect("off"),
            Discoverability::Off
        );
        assert_eq!(
            parse_discoverability("private")
                .expect_err("invalid discoverability")
                .code,
            "invalid_request"
        );
    }

    #[test]
    fn node_command_requires_operation_fields() {
        let missing_endpoint: NodeCommandRequest = parse_request(
            &serde_json::json!({
                "sessionId": "node-1",
                "operation": "forgetPaired"
            })
            .to_string(),
        )
        .expect("parse command");
        assert_eq!(
            missing_endpoint
                .validate()
                .expect_err("endpointId required")
                .code,
            "invalid_request"
        );

        let missing_bool: NodeCommandRequest = parse_request(
            &serde_json::json!({
                "sessionId": "node-1",
                "operation": "respondNearbyInvite",
                "endpointId": "peer",
                "accept": false
            })
            .to_string(),
        )
        .expect("parse command");
        assert_eq!(
            missing_bool.validate().expect_err("block required").code,
            "invalid_request"
        );

        let missing_size: NodeCommandRequest = parse_request(
            &serde_json::json!({
                "sessionId": "node-1",
                "operation": "invitePaired",
                "endpointId": "peer",
                "blobTicket": "ticket",
                "fileCount": 1
            })
            .to_string(),
        )
        .expect("parse command");
        assert_eq!(
            missing_size
                .validate()
                .expect_err("totalSize required")
                .code,
            "invalid_request"
        );
    }
}
