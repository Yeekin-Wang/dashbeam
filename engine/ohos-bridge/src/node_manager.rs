use crate::error::BridgeError;
use crate::events::{
    emit_event, emit_terminal_event, error_payload, CallbackSlot, SessionEventEmitter,
};
use crate::request::{NodeCommand, ValidatedNodeCommand, ValidatedNodeStart};
use native::NodeService;
use protocol::AppHandle;
use serde::Serialize;
use serde_json::{json, Value};
use std::fmt::Display;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

struct NodeManager {
    state: Mutex<NodeState>,
}

enum NodeState {
    Stopped,
    Starting {
        session_id: String,
        callback: CallbackSlot,
        stop_requested: bool,
    },
    Running {
        session_id: String,
        service: Arc<NodeService>,
        callback: CallbackSlot,
    },
    Stopping {
        session_id: String,
    },
}

enum StatusSnapshot {
    Stopped,
    Starting {
        session_id: String,
        stop_requested: bool,
    },
    Ready {
        session_id: String,
        service: Arc<NodeService>,
    },
    Stopping {
        session_id: String,
    },
}

static NODE_MANAGER: OnceLock<NodeManager> = OnceLock::new();

fn manager() -> &'static NodeManager {
    NODE_MANAGER.get_or_init(NodeManager::new)
}

impl NodeManager {
    fn new() -> Self {
        Self {
            state: Mutex::new(NodeState::Stopped),
        }
    }

    fn lock(&self) -> MutexGuard<'_, NodeState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn reserve_start(&self, session_id: &str, callback: CallbackSlot) -> Result<(), BridgeError> {
        let mut state = self.lock();
        if !matches!(*state, NodeState::Stopped) {
            return Err(BridgeError::new(
                "node_already_started",
                "the process node is already starting, ready, or stopping",
            ));
        }

        *state = NodeState::Starting {
            session_id: session_id.to_string(),
            callback,
            stop_requested: false,
        };
        Ok(())
    }

    fn stop(&self, session_id: &str) -> Result<Value, BridgeError> {
        let mut shutdown_plan = None;
        let response = {
            let mut state = self.lock();
            match &mut *state {
                NodeState::Stopped => json!({
                    "accepted": false,
                    "idempotent": true,
                    "status": "stopped",
                    "sessionId": session_id,
                }),
                NodeState::Starting {
                    session_id: active_session,
                    stop_requested,
                    ..
                } => {
                    ensure_session(active_session, session_id)?;
                    *stop_requested = true;
                    json!({
                        "accepted": true,
                        "status": "starting",
                        "stopRequested": true,
                        "sessionId": active_session,
                    })
                }
                NodeState::Running {
                    session_id: active_session,
                    service,
                    callback,
                } => {
                    ensure_session(active_session, session_id)?;
                    let active_session = active_session.clone();
                    shutdown_plan =
                        Some((active_session.clone(), service.clone(), callback.clone()));
                    *state = NodeState::Stopping {
                        session_id: active_session.clone(),
                    };
                    json!({
                        "accepted": true,
                        "status": "stopping",
                        "sessionId": active_session,
                    })
                }
                NodeState::Stopping {
                    session_id: active_session,
                } => {
                    ensure_session(active_session, session_id)?;
                    json!({
                        "accepted": false,
                        "idempotent": true,
                        "status": "stopping",
                        "sessionId": active_session,
                    })
                }
            }
        };

        if let Some((session_id, service, callback)) = shutdown_plan {
            spawn_shutdown(session_id, service, callback);
        }

        Ok(response)
    }

    fn running_service(&self) -> Result<Arc<NodeService>, BridgeError> {
        let state = self.lock();
        match &*state {
            NodeState::Running { service, .. } => Ok(service.clone()),
            NodeState::Stopped => Err(BridgeError::new(
                "node_not_ready",
                "the process node is stopped",
            )),
            NodeState::Starting { .. } => Err(BridgeError::new(
                "node_not_ready",
                "the process node is still starting",
            )),
            NodeState::Stopping { .. } => Err(BridgeError::new(
                "node_not_ready",
                "the process node is stopping",
            )),
        }
    }

    fn snapshot(&self) -> StatusSnapshot {
        let state = self.lock();
        match &*state {
            NodeState::Stopped => StatusSnapshot::Stopped,
            NodeState::Starting {
                session_id,
                stop_requested,
                ..
            } => StatusSnapshot::Starting {
                session_id: session_id.clone(),
                stop_requested: *stop_requested,
            },
            NodeState::Running {
                session_id,
                service,
                ..
            } => StatusSnapshot::Ready {
                session_id: session_id.clone(),
                service: service.clone(),
            },
            NodeState::Stopping { session_id } => StatusSnapshot::Stopping {
                session_id: session_id.clone(),
            },
        }
    }
}

fn ensure_session(active_session: &str, requested_session: &str) -> Result<(), BridgeError> {
    if active_session == requested_session {
        return Ok(());
    }

    Err(BridgeError::new(
        "node_session_mismatch",
        format!("node belongs to sessionId {active_session}"),
    ))
}

pub fn start(request: ValidatedNodeStart, callback: CallbackSlot) -> Result<(), BridgeError> {
    let _ = crate::runtime::runtime();
    manager().reserve_start(&request.session_id, callback.clone())?;
    spawn_start(request, callback);
    Ok(())
}

fn spawn_start(request: ValidatedNodeStart, callback: CallbackSlot) {
    let session_id = request.session_id.clone();
    let monitor_session_id = session_id.clone();
    let monitor_callback = callback.clone();
    let task = crate::runtime::runtime().spawn(run_start(request, callback));

    crate::runtime::runtime().spawn(async move {
        if let Err(join_error) = task.await {
            let reason = if join_error.is_panic() {
                "node lifecycle task panicked"
            } else {
                "node lifecycle task was cancelled"
            };
            recover_lifecycle_task(&monitor_session_id, monitor_callback, reason);
        }
    });
}

async fn run_start(request: ValidatedNodeStart, callback: CallbackSlot) {
    let session_id = request.session_id;
    let app_handle: AppHandle = Some(Arc::new(SessionEventEmitter::node(
        callback.clone(),
        session_id.clone(),
    )));

    let service =
        match NodeService::start_default(&request.data_dir, request.discoverability, app_handle)
            .await
        {
            Ok(service) => Arc::new(service),
            Err(error) => {
                finish_start_failure(
                    &session_id,
                    callback,
                    BridgeError::new("node_start_failed", error.to_string()),
                );
                return;
            }
        };

    if let Err(profile_error) = service.set_public_profile(
        request.display_name.as_deref(),
        request.device_type.as_deref(),
    ) {
        let shutdown_error = service.shutdown().await.err();
        let message = match shutdown_error {
            Some(shutdown_error) => format!(
                "failed to persist device profile: {profile_error}; shutdown also failed: {shutdown_error}"
            ),
            None => format!("failed to persist device profile: {profile_error}"),
        };
        finish_start_failure(
            &session_id,
            callback,
            BridgeError::new("node_start_failed", message),
        );
        return;
    }

    let ready_data = json!({
        "deviceInfo": service.device_info(),
        "networkReady": service.is_network_ready(),
    });
    let landing = {
        let mut state = manager().lock();
        match &*state {
            NodeState::Starting {
                session_id: active_session,
                stop_requested,
                ..
            } if active_session == &session_id => {
                if *stop_requested {
                    *state = NodeState::Stopping {
                        session_id: session_id.clone(),
                    };
                    Some(true)
                } else {
                    *state = NodeState::Running {
                        session_id: session_id.clone(),
                        service: service.clone(),
                        callback: callback.clone(),
                    };
                    Some(false)
                }
            }
            _ => None,
        }
    };

    let Some(stop_requested) = landing else {
        let _ = service.shutdown().await;
        return;
    };

    emit_event(callback.clone(), &session_id, "node-ready", ready_data);
    if stop_requested {
        shutdown_and_finish(&session_id, service, callback).await;
    }
}

fn finish_start_failure(session_id: &str, callback: CallbackSlot, error: BridgeError) {
    let should_emit = {
        let mut state = manager().lock();
        match &*state {
            NodeState::Starting {
                session_id: active_session,
                ..
            } if active_session == session_id => {
                *state = NodeState::Stopped;
                true
            }
            _ => false,
        }
    };

    if should_emit {
        emit_terminal_event(
            callback,
            session_id,
            "operation-failed",
            lifecycle_error_payload("startNode", error),
        );
    }
}

pub fn stop(session_id: &str) -> Result<Value, BridgeError> {
    manager().stop(session_id)
}

fn spawn_shutdown(session_id: String, service: Arc<NodeService>, callback: CallbackSlot) {
    let monitor_session_id = session_id.clone();
    let monitor_callback = callback.clone();
    let task = crate::runtime::runtime().spawn(async move {
        shutdown_and_finish(&session_id, service, callback).await;
    });

    crate::runtime::runtime().spawn(async move {
        if let Err(join_error) = task.await {
            let reason = if join_error.is_panic() {
                "node shutdown task panicked"
            } else {
                "node shutdown task was cancelled"
            };
            recover_lifecycle_task(&monitor_session_id, monitor_callback, reason);
        }
    });
}

async fn shutdown_and_finish(session_id: &str, service: Arc<NodeService>, callback: CallbackSlot) {
    let shutdown_result = service.shutdown().await;
    let should_emit = {
        let mut state = manager().lock();
        match &*state {
            NodeState::Stopping {
                session_id: active_session,
            } if active_session == session_id => {
                *state = NodeState::Stopped;
                true
            }
            _ => false,
        }
    };

    if should_emit {
        let data = match shutdown_result {
            Ok(()) => json!({ "status": "stopped" }),
            Err(error) => json!({
                "status": "stopped",
                "error": {
                    "code": "node_shutdown_failed",
                    "message": error.to_string(),
                }
            }),
        };
        emit_terminal_event(callback, session_id, "node-stopped", data);
    }
}

fn recover_lifecycle_task(session_id: &str, callback: CallbackSlot, reason: &str) {
    enum RecoveryEvent {
        StartFailed,
        Stopped,
        None,
    }

    let event = {
        let mut state = manager().lock();
        match &*state {
            NodeState::Starting {
                session_id: active_session,
                ..
            } if active_session == session_id => {
                *state = NodeState::Stopped;
                RecoveryEvent::StartFailed
            }
            NodeState::Stopping {
                session_id: active_session,
            } if active_session == session_id => {
                *state = NodeState::Stopped;
                RecoveryEvent::Stopped
            }
            _ => RecoveryEvent::None,
        }
    };

    let error = BridgeError::internal(reason);
    match event {
        RecoveryEvent::StartFailed => emit_terminal_event(
            callback,
            session_id,
            "operation-failed",
            lifecycle_error_payload("startNode", error),
        ),
        RecoveryEvent::Stopped => emit_terminal_event(
            callback,
            session_id,
            "node-stopped",
            json!({
                "status": "stopped",
                "error": error_payload(error),
            }),
        ),
        RecoveryEvent::None => {}
    }
}

pub fn command(request: ValidatedNodeCommand, callback: CallbackSlot) -> Result<(), BridgeError> {
    let service = manager().running_service()?;
    spawn_command(request.session_id, request.command, service, callback);
    Ok(())
}

fn spawn_command(
    session_id: String,
    command: NodeCommand,
    service: Arc<NodeService>,
    callback: CallbackSlot,
) {
    let operation = command.operation();
    let monitor_operation = operation;
    let monitor_session_id = session_id.clone();
    let monitor_callback = callback.clone();
    let task = crate::runtime::runtime().spawn(async move {
        match execute_command(service, command).await {
            Ok(result) => emit_terminal_event(
                callback,
                &session_id,
                "node-command-completed",
                json!({
                    "operation": operation,
                    "result": result,
                }),
            ),
            Err(error) => emit_terminal_event(
                callback,
                &session_id,
                "operation-failed",
                lifecycle_error_payload(operation, error),
            ),
        }
    });

    crate::runtime::runtime().spawn(async move {
        if let Err(join_error) = task.await {
            let reason = if join_error.is_panic() {
                "node command task panicked"
            } else {
                "node command task was cancelled"
            };
            emit_terminal_event(
                monitor_callback,
                &monitor_session_id,
                "operation-failed",
                lifecycle_error_payload(monitor_operation, BridgeError::internal(reason)),
            );
        }
    });
}

async fn execute_command(
    service: Arc<NodeService>,
    command: NodeCommand,
) -> Result<Value, BridgeError> {
    let operation = command.operation();
    match command {
        NodeCommand::GetDeviceInfo => serialize_command_result(operation, service.device_info()),
        NodeCommand::ListPaired => {
            let devices = service
                .list_paired()
                .map_err(|error| command_error(operation, error))?;
            serialize_command_result(operation, devices)
        }
        NodeCommand::ListNearby => serialize_command_result(operation, service.list_nearby().await),
        NodeCommand::StartPairingHost { ttl_secs } => {
            let ticket = service
                .start_pairing_host(ttl_secs)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "ticket": ticket }))
        }
        NodeCommand::StopPairingHost => {
            service.stop_pairing_host().await;
            Ok(json!({ "stopped": true }))
        }
        NodeCommand::JoinPairing { ticket } => {
            service
                .join_pairing(&ticket)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "joined": true }))
        }
        NodeCommand::ForgetPaired { endpoint_id } => {
            service
                .forget_paired(&endpoint_id)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "forgotten": true, "endpointId": endpoint_id }))
        }
        NodeCommand::RequestNearbyPair { endpoint_id } => {
            let delivered = service
                .request_nearby_pair(&endpoint_id)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "delivered": delivered }))
        }
        NodeCommand::RespondNearbyInvite {
            endpoint_id,
            accept,
            block,
        } => {
            if accept {
                service
                    .accept_nearby_invite(&endpoint_id)
                    .await
                    .map_err(|error| command_error(operation, error))?;
            } else {
                service
                    .decline_nearby_invite(&endpoint_id, block)
                    .await
                    .map_err(|error| command_error(operation, error))?;
            }
            Ok(json!({ "accepted": accept, "blocked": !accept && block }))
        }
        NodeCommand::RenameDevice { display_name } => {
            let device_info = service
                .set_device_display_name(&display_name)
                .map_err(|error| command_error(operation, error))?;
            serialize_command_result(operation, device_info)
        }
        NodeCommand::RenamePaired {
            endpoint_id,
            display_name,
        } => {
            let device = service
                .rename_paired(&endpoint_id, &display_name)
                .map_err(|error| command_error(operation, error))?;
            serialize_command_result(operation, device)
        }
        NodeCommand::SetDiscoverability { discoverability } => {
            service
                .set_discoverability(discoverability)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "discoverability": discoverability }))
        }
        NodeCommand::InvitePaired {
            endpoint_id,
            blob_ticket,
            file_count,
            total_size,
        } => {
            let delivered = service
                .invite_paired_device(&endpoint_id, &blob_ticket, file_count, total_size)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "delivered": delivered }))
        }
        NodeCommand::InviteNearby {
            endpoint_id,
            blob_ticket,
            file_count,
            total_size,
        } => {
            let delivered = service
                .invite_nearby_device(&endpoint_id, &blob_ticket, file_count, total_size)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "delivered": delivered }))
        }
        NodeCommand::RespondPairedInvite {
            endpoint_id,
            accept,
        } => {
            service
                .respond_paired_invite(&endpoint_id, accept)
                .await
                .map_err(|error| command_error(operation, error))?;
            Ok(json!({ "accepted": accept }))
        }
    }
}

fn serialize_command_result<T: Serialize>(operation: &str, value: T) -> Result<Value, BridgeError> {
    serde_json::to_value(value).map_err(|error| command_error(operation, error))
}

fn command_error(operation: &str, error: impl Display) -> BridgeError {
    BridgeError::new(
        "node_command_failed",
        format!("{operation} failed: {error}"),
    )
}

fn lifecycle_error_payload(operation: &str, error: BridgeError) -> Value {
    let mut payload = error_payload(error);
    if let Value::Object(fields) = &mut payload {
        fields.insert(
            "operation".to_string(),
            Value::String(operation.to_string()),
        );
    }
    payload
}

pub fn status() -> Value {
    match manager().snapshot() {
        StatusSnapshot::Stopped => json!({ "status": "stopped" }),
        StatusSnapshot::Starting {
            session_id,
            stop_requested,
        } => json!({
            "status": "starting",
            "sessionId": session_id,
            "stopRequested": stop_requested,
        }),
        StatusSnapshot::Ready {
            session_id,
            service,
        } => json!({
            "status": "ready",
            "sessionId": session_id,
            "networkReady": service.is_network_ready(),
            "deviceInfo": service.device_info(),
        }),
        StatusSnapshot::Stopping { session_id } => json!({
            "status": "stopping",
            "sessionId": session_id,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_start_is_rejected_without_network() {
        let manager = NodeManager::new();
        manager
            .reserve_start("node-1", CallbackSlot::none())
            .expect("first start");

        let error = manager
            .reserve_start("node-2", CallbackSlot::none())
            .expect_err("duplicate start");
        assert_eq!(error.code, "node_already_started");
    }

    #[test]
    fn stop_during_start_sets_stop_requested_without_network() {
        let manager = NodeManager::new();
        manager
            .reserve_start("node-1", CallbackSlot::none())
            .expect("reserve start");

        let response = manager.stop("node-1").expect("request stop");
        assert_eq!(response["status"], "starting");
        assert_eq!(response["stopRequested"], true);

        match manager.snapshot() {
            StatusSnapshot::Starting { stop_requested, .. } => assert!(stop_requested),
            _ => panic!("expected starting state"),
        }
    }
}
