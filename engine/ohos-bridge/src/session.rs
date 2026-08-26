use crate::error::BridgeError;
use crate::events::CallbackSlot;
use native::SendResult;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use tokio::sync::oneshot;
use tokio::task::AbortHandle;

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionKind {
    Share,
    Receive,
    Metadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionState {
    Accepted,
    Running,
    ShareReady,
    Completed,
    Failed,
    Cancelled,
}

impl SessionState {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            SessionState::Completed | SessionState::Failed | SessionState::Cancelled
        )
    }
}

enum CancelControl {
    None,
    Abortable {
        abort_handle: Option<AbortHandle>,
    },
    Receive {
        cancel_tx: Option<oneshot::Sender<()>>,
        abort_handle: Option<AbortHandle>,
    },
    ShareReady,
}

struct SessionRecord {
    kind: SessionKind,
    state: SessionState,
    error: Option<BridgeError>,
    callback: CallbackSlot,
    cancel: CancelControl,
    share_guard: Option<SendResult>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSnapshot {
    pub session_id: String,
    pub kind: SessionKind,
    pub state: SessionState,
    pub terminal: bool,
    pub error: Option<BridgeError>,
}

#[derive(Default)]
pub struct CancelPlan {
    pub callback: CallbackSlot,
    pub cancel_tx: Option<oneshot::Sender<()>>,
    pub abort_handle: Option<AbortHandle>,
    pub share_guard: Option<SendResult>,
}

static SESSIONS: OnceLock<Mutex<HashMap<String, SessionRecord>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<String, SessionRecord>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn active_count() -> usize {
    let guard = sessions().lock().expect("sessions mutex poisoned");
    guard
        .values()
        .filter(|record| !record.state.is_terminal())
        .count()
}

pub fn insert_session(
    session_id: &str,
    kind: SessionKind,
    callback: CallbackSlot,
) -> Result<(), BridgeError> {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    if guard.contains_key(session_id) {
        return Err(BridgeError::new(
            "duplicate_session",
            format!("sessionId already exists: {session_id}"),
        ));
    }

    guard.insert(
        session_id.to_string(),
        SessionRecord {
            kind,
            state: SessionState::Accepted,
            error: None,
            callback,
            cancel: CancelControl::None,
            share_guard: None,
        },
    );
    Ok(())
}

pub fn mark_running(session_id: &str) {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    if let Some(record) = guard.get_mut(session_id) {
        if record.state == SessionState::Accepted {
            record.state = SessionState::Running;
        }
    }
}

pub fn set_abortable_cancel(session_id: &str, abort_handle: AbortHandle) {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    if let Some(record) = guard.get_mut(session_id) {
        if matches!(record.state, SessionState::Accepted | SessionState::Running) {
            record.cancel = CancelControl::Abortable {
                abort_handle: Some(abort_handle),
            };
        }
    }
}

pub fn set_receive_cancel(
    session_id: &str,
    cancel_tx: oneshot::Sender<()>,
    abort_handle: AbortHandle,
) {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    if let Some(record) = guard.get_mut(session_id) {
        if matches!(record.state, SessionState::Accepted | SessionState::Running) {
            record.cancel = CancelControl::Receive {
                cancel_tx: Some(cancel_tx),
                abort_handle: Some(abort_handle),
            };
        }
    }
}

pub fn set_share_ready(session_id: &str, send_result: SendResult) -> Option<CallbackSlot> {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    let Some(record) = guard.get_mut(session_id) else {
        return None;
    };

    if record.state.is_terminal() {
        return None;
    }

    record.state = SessionState::ShareReady;
    record.error = None;
    record.cancel = CancelControl::ShareReady;
    record.share_guard = Some(send_result);
    Some(record.callback.clone())
}

pub fn complete(session_id: &str) -> Option<CallbackSlot> {
    transition_terminal(session_id, SessionState::Completed, None)
}

pub fn cancelled(session_id: &str) -> Option<CallbackSlot> {
    transition_terminal(session_id, SessionState::Cancelled, None)
}

pub fn fail(session_id: &str, error: BridgeError) -> Option<CallbackSlot> {
    transition_terminal(session_id, SessionState::Failed, Some(error))
}

fn transition_terminal(
    session_id: &str,
    next_state: SessionState,
    error: Option<BridgeError>,
) -> Option<CallbackSlot> {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    let Some(record) = guard.get_mut(session_id) else {
        return None;
    };

    if record.state.is_terminal() {
        return None;
    }

    record.state = next_state;
    record.error = error;
    record.cancel = CancelControl::None;
    record.share_guard = None;
    let callback = record.callback.clone();
    record.callback = CallbackSlot::none();
    Some(callback)
}

pub fn cancel(session_id: &str) -> Result<CancelPlan, BridgeError> {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    let Some(record) = guard.get_mut(session_id) else {
        return Err(BridgeError::new(
            "session_not_found",
            format!("unknown sessionId: {session_id}"),
        ));
    };

    if record.state.is_terminal() {
        return Ok(CancelPlan::default());
    }

    record.state = SessionState::Cancelled;
    record.error = None;

    let callback = record.callback.clone();
    record.callback = CallbackSlot::none();

    let mut plan = CancelPlan {
        callback,
        ..Default::default()
    };

    match &mut record.cancel {
        CancelControl::None => {}
        CancelControl::Abortable { abort_handle } => {
            plan.abort_handle = abort_handle.take();
        }
        CancelControl::Receive {
            cancel_tx,
            abort_handle,
        } => {
            plan.cancel_tx = cancel_tx.take();
            plan.abort_handle = abort_handle.take();
        }
        CancelControl::ShareReady => {
            plan.share_guard = record.share_guard.take();
        }
    }

    record.cancel = CancelControl::None;
    Ok(plan)
}

pub fn get_snapshot(session_id: &str) -> Option<SessionSnapshot> {
    let guard = sessions().lock().expect("sessions mutex poisoned");
    guard.get(session_id).map(|record| SessionSnapshot {
        session_id: session_id.to_string(),
        kind: record.kind,
        state: record.state,
        terminal: record.state.is_terminal(),
        error: record.error.clone(),
    })
}

#[cfg(test)]
pub fn remove_session(session_id: &str) {
    let mut guard = sessions().lock().expect("sessions mutex poisoned");
    guard.remove(session_id);
}
