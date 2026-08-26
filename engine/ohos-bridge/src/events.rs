use crate::error::BridgeError;
use protocol::EventEmitter;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

pub type EventCallback = unsafe extern "C" fn(*const c_char, bool, *mut c_void);

#[derive(Clone)]
pub struct CallbackSlot {
    inner: Arc<CallbackState>,
}

struct CallbackState {
    callback: Option<EventCallback>,
    user_data: usize,
    closed: AtomicBool,
    dispatch: Mutex<()>,
}

static CALLBACKS: OnceLock<Mutex<HashMap<usize, Vec<Weak<CallbackState>>>>> = OnceLock::new();

fn callbacks() -> &'static Mutex<HashMap<usize, Vec<Weak<CallbackState>>>> {
    CALLBACKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn unregister_callback(user_data: usize, target: &Arc<CallbackState>) {
    let mut callbacks = callbacks()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let remove_entry = if let Some(states) = callbacks.get_mut(&user_data) {
        states.retain(|state| {
            state
                .upgrade()
                .is_some_and(|state| !Arc::ptr_eq(&state, target))
        });
        states.is_empty()
    } else {
        false
    };
    if remove_entry {
        callbacks.remove(&user_data);
    }
}

pub fn detach_callback(user_data: *mut c_void) {
    let states = callbacks()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&(user_data as usize))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|state| state.upgrade())
        .collect::<Vec<_>>();

    for state in states {
        let _guard = state
            .dispatch
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.closed.store(true, Ordering::Release);
    }
}

impl CallbackSlot {
    pub fn new(callback: Option<EventCallback>, user_data: *mut c_void) -> Self {
        let inner = Arc::new(CallbackState {
            callback,
            user_data: user_data as usize,
            closed: AtomicBool::new(false),
            dispatch: Mutex::new(()),
        });
        if callback.is_some() && !user_data.is_null() {
            callbacks()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .entry(user_data as usize)
                .or_default()
                .push(Arc::downgrade(&inner));
        }
        Self { inner }
    }

    pub fn none() -> Self {
        Self::new(None, std::ptr::null_mut())
    }

    fn dispatch(&self, payload: CString, terminal: bool) {
        let _guard = self
            .inner
            .dispatch
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if self.inner.closed.load(Ordering::Acquire) {
            return;
        }
        if terminal {
            self.inner.closed.store(true, Ordering::Release);
        }

        if let Some(callback) = self.inner.callback {
            unsafe {
                callback(
                    payload.as_ptr(),
                    terminal,
                    self.inner.user_data as *mut c_void,
                );
            }
        }

        if terminal {
            unregister_callback(self.inner.user_data, &self.inner);
        }
    }
}

impl Default for CallbackSlot {
    fn default() -> Self {
        Self::none()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EventEnvelope<'a> {
    session_id: &'a str,
    event_name: &'a str,
    data: Value,
}

fn envelope_json(session_id: &str, event_name: &str, data: Value) -> String {
    serde_json::to_string(&EventEnvelope {
        session_id,
        event_name,
        data,
    })
    .unwrap_or_else(|_| {
        "{\"sessionId\":\"\",\"eventName\":\"operation-failed\",\"data\":{\"code\":\"internal\",\"message\":\"failed to serialize event\"}}".to_string()
    })
}

pub fn error_payload(error: BridgeError) -> Value {
    serde_json::json!({
        "code": error.code,
        "message": error.message,
    })
}

fn dispatch_event(
    slot: CallbackSlot,
    session_id: &str,
    event_name: &str,
    data: Value,
    terminal: bool,
) {
    let payload = envelope_json(session_id, event_name, data);
    if let Ok(c_payload) = CString::new(payload) {
        slot.dispatch(c_payload, terminal);
    }
}

pub fn emit_event(slot: CallbackSlot, session_id: &str, event_name: &str, data: Value) {
    dispatch_event(slot, session_id, event_name, data, false);
}

pub fn emit_terminal_event(slot: CallbackSlot, session_id: &str, event_name: &str, data: Value) {
    dispatch_event(slot, session_id, event_name, data, true);
}

pub struct SessionEventEmitter {
    callback: CallbackSlot,
    session_id: String,
    suppress_receive_completed: bool,
}

impl SessionEventEmitter {
    pub fn node(callback: CallbackSlot, session_id: String) -> Self {
        Self {
            callback,
            session_id,
            suppress_receive_completed: false,
        }
    }

    pub fn share(callback: CallbackSlot, session_id: String) -> Self {
        Self {
            callback,
            session_id,
            suppress_receive_completed: false,
        }
    }

    pub fn receive(callback: CallbackSlot, session_id: String) -> Self {
        Self {
            callback,
            session_id,
            suppress_receive_completed: true,
        }
    }

    fn forward(&self, event_name: &str, data: Value) {
        if self.suppress_receive_completed && event_name == "receive-completed" {
            return;
        }
        emit_event(self.callback.clone(), &self.session_id, event_name, data);
    }
}

impl EventEmitter for SessionEventEmitter {
    fn emit_event(&self, event_name: &str) -> Result<(), String> {
        self.forward(event_name, serde_json::json!({}));
        Ok(())
    }

    fn emit_event_with_payload(&self, event_name: &str, payload: &str) -> Result<(), String> {
        let data =
            serde_json::from_str(payload).unwrap_or_else(|_| Value::String(payload.to_owned()));
        self.forward(event_name, data);
        Ok(())
    }
}

#[cfg(test)]
pub fn emit_event_for_test(slot: CallbackSlot, session_id: &str, event_name: &str, data: Value) {
    emit_event(slot, session_id, event_name, data);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static CALLBACK_COUNT: AtomicUsize = AtomicUsize::new(0);

    unsafe extern "C" fn count_callback(
        _payload: *const c_char,
        _terminal: bool,
        _user_data: *mut c_void,
    ) {
        CALLBACK_COUNT.fetch_add(1, Ordering::SeqCst);
    }

    #[test]
    fn terminal_slot_does_not_unregister_sibling_callback() {
        CALLBACK_COUNT.store(0, Ordering::SeqCst);
        let user_data = 0x55aausize as *mut c_void;
        let node_slot = CallbackSlot::new(Some(count_callback), user_data);
        let command_slot = CallbackSlot::new(Some(count_callback), user_data);

        emit_terminal_event(
            command_slot,
            "node-1",
            "node-command-completed",
            serde_json::json!({}),
        );
        detach_callback(user_data);
        emit_event(node_slot, "node-1", "device-found", serde_json::json!({}));

        assert_eq!(CALLBACK_COUNT.load(Ordering::SeqCst), 1);
    }
}
