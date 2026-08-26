mod error;
mod events;
mod node_manager;
mod request;
mod runtime;
mod session;

use crate::error::{error_json, BridgeError};
use crate::events::{
    emit_event, emit_terminal_event, error_payload, CallbackSlot, EventCallback,
    SessionEventEmitter,
};
use crate::request::{
    MetadataRequest, NodeCommandRequest, NodeStartRequest, ReceiveRequest, SessionRequest,
    ShareRequest,
};
use crate::session::{SessionKind, SessionSnapshot};
use serde::Serialize;
use serde_json::json;
use std::ffi::{c_char, c_void, CStr, CString};
use std::future::Future;
use std::sync::Arc;
use tokio::sync::oneshot;
use tokio::task::AbortHandle;

const ABI_VERSION: u32 = 2;

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"response contains a null byte\"}}")
                .expect("literal CString")
        })
        .into_raw()
}

fn serialize_ok<T: Serialize>(payload: T) -> String {
    serde_json::to_string(&json!({ "ok": true, "data": payload }))
        .unwrap_or_else(|_| error_json(BridgeError::internal("failed to serialize ok response")))
}

fn json_ptr(value: String) -> *mut c_char {
    into_c_string(value)
}

fn error_ptr(error: BridgeError) -> *mut c_char {
    json_ptr(error_json(error))
}

fn ffi_boundary<F>(func: F) -> *mut c_char
where
    F: FnOnce() -> Result<String, BridgeError>,
{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(func)) {
        Ok(Ok(value)) => json_ptr(value),
        Ok(Err(error)) => error_ptr(error),
        Err(_) => error_ptr(BridgeError::internal("panic while handling FFI call")),
    }
}

unsafe fn read_json_request(ptr: *const c_char) -> Result<String, BridgeError> {
    if ptr.is_null() {
        return Err(BridgeError::invalid_request("request_json is null"));
    }

    let bytes = unsafe { CStr::from_ptr(ptr) }.to_bytes();
    let value = std::str::from_utf8(bytes)
        .map_err(|_| BridgeError::new("invalid_utf8", "request JSON is not valid UTF-8"))?;
    Ok(value.to_owned())
}

fn accepted_json(session_id: &str, operation: &str) -> String {
    serialize_ok(json!({
        "accepted": true,
        "sessionId": session_id,
        "operation": operation,
    }))
}

fn emit_operation_failed(slot: CallbackSlot, session_id: &str, error: BridgeError) {
    emit_terminal_event(slot, session_id, "operation-failed", error_payload(error));
}

fn spawn_session_task<F>(session_id: String, future: F) -> AbortHandle
where
    F: Future<Output = ()> + Send + 'static,
{
    let task = runtime::runtime().spawn(future);
    let abort_handle = task.abort_handle();

    runtime::runtime().spawn(async move {
        if let Err(join_error) = task.await {
            if join_error.is_panic() {
                let error = BridgeError::internal("background engine task panicked");
                if let Some(slot) = session::fail(&session_id, error.clone()) {
                    emit_operation_failed(slot, &session_id, error);
                }
            } else if join_error.is_cancelled() {
                if let Some(slot) = session::cancelled(&session_id) {
                    emit_terminal_event(
                        slot,
                        &session_id,
                        "operation-cancelled",
                        json!({ "reason": "task cancelled" }),
                    );
                }
            }
        }
    });

    abort_handle
}

#[no_mangle]
pub extern "C" fn dashbeam_engine_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn dashbeam_engine_status() -> *mut c_char {
    ffi_boundary(|| {
        Ok(serialize_ok(json!({
            "abiVersion": ABI_VERSION,
            "rustLinked": true,
            "activeSessions": session::active_count(),
        })))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_start_node(
    request_json: *const c_char,
    callback: Option<EventCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: NodeStartRequest = request::parse_request(&request)?;
        let validated = parsed.validate()?;
        let session_id = validated.session_id.clone();

        node_manager::start(validated, CallbackSlot::new(callback, user_data))?;
        Ok(accepted_json(&session_id, "startNode"))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_stop_node(request_json: *const c_char) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: SessionRequest = request::parse_request(&request)?;
        let session_id = parsed.validate()?;
        Ok(serialize_ok(node_manager::stop(&session_id)?))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_node_command(
    request_json: *const c_char,
    callback: Option<EventCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: NodeCommandRequest = request::parse_request(&request)?;
        let validated = parsed.validate()?;
        let session_id = validated.session_id.clone();
        let operation = validated.command.operation();

        node_manager::command(validated, CallbackSlot::new(callback, user_data))?;
        Ok(accepted_json(&session_id, operation))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_node_status() -> *mut c_char {
    ffi_boundary(|| Ok(serialize_ok(node_manager::status())))
}

#[no_mangle]
pub extern "C" fn dashbeam_start_share(
    request_json: *const c_char,
    callback: Option<EventCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: ShareRequest = request::parse_request(&request)?;
        let (session_id, paths, metadata, send_options) = parsed.validate()?;

        let callback_slot = CallbackSlot::new(callback, user_data);
        session::insert_session(&session_id, SessionKind::Share, callback_slot.clone())?;

        let task_session_id = session_id.clone();
        let app_handle: protocol::AppHandle = Some(Arc::new(SessionEventEmitter::share(
            callback_slot,
            session_id.clone(),
        )));
        let abort_handle = spawn_session_task(task_session_id.clone(), async move {
            session::mark_running(&task_session_id);

            match native::start_share_items(paths, send_options, &app_handle, metadata).await {
                Ok(result) => {
                    let payload = json!({
                        "ticket": result.ticket,
                        "hash": result.hash,
                        "size": result.size,
                        "entryType": result.entry_type,
                    });
                    if let Some(slot) = session::set_share_ready(&task_session_id, result) {
                        emit_event(slot, &task_session_id, "share-ready", payload);
                    }
                }
                Err(err) => {
                    let bridge_error = BridgeError::new("share_failed", err.to_string());
                    if let Some(slot) = session::fail(&task_session_id, bridge_error.clone()) {
                        emit_operation_failed(slot, &task_session_id, bridge_error);
                    }
                }
            }
        });

        session::set_abortable_cancel(&session_id, abort_handle);
        Ok(accepted_json(&session_id, "share"))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_start_receive(
    request_json: *const c_char,
    callback: Option<EventCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: ReceiveRequest = request::parse_request(&request)?;
        let (session_id, ticket, receive_options) = parsed.validate()?;

        let callback_slot = CallbackSlot::new(callback, user_data);
        session::insert_session(&session_id, SessionKind::Receive, callback_slot.clone())?;

        let (cancel_tx, cancel_rx) = oneshot::channel();
        let task_session_id = session_id.clone();
        let terminal_callback = callback_slot.clone();
        let app_handle: protocol::AppHandle = Some(Arc::new(SessionEventEmitter::receive(
            callback_slot,
            session_id.clone(),
        )));
        let abort_handle = spawn_session_task(task_session_id.clone(), async move {
            session::mark_running(&task_session_id);

            match native::download(ticket, receive_options, app_handle, cancel_rx).await {
                Ok(result) => {
                    let payload = json!({
                        "message": result.message,
                        "filePath": result.file_path,
                    });
                    if let Some(slot) = session::complete(&task_session_id) {
                        emit_terminal_event(slot, &task_session_id, "receive-completed", payload);
                    }
                }
                Err(err) => {
                    let text = err.to_string();
                    if text.contains("cancelled") {
                        let slot = session::cancelled(&task_session_id)
                            .unwrap_or_else(|| terminal_callback.clone());
                        emit_terminal_event(
                            slot,
                            &task_session_id,
                            "operation-cancelled",
                            json!({ "reason": "cancelled" }),
                        );
                    } else {
                        let bridge_error = BridgeError::new("receive_failed", text);
                        if let Some(slot) = session::fail(&task_session_id, bridge_error.clone()) {
                            emit_operation_failed(slot, &task_session_id, bridge_error);
                        }
                    }
                }
            }
        });

        session::set_receive_cancel(&session_id, cancel_tx, abort_handle);
        Ok(accepted_json(&session_id, "receive"))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_fetch_metadata(
    request_json: *const c_char,
    callback: Option<EventCallback>,
    user_data: *mut c_void,
) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: MetadataRequest = request::parse_request(&request)?;
        let (session_id, ticket, receive_options) = parsed.validate()?;

        let callback_slot = CallbackSlot::new(callback, user_data);
        session::insert_session(&session_id, SessionKind::Metadata, callback_slot.clone())?;

        let task_session_id = session_id.clone();
        let abort_handle = spawn_session_task(task_session_id.clone(), async move {
            session::mark_running(&task_session_id);

            match protocol::fetch_metadata(ticket, receive_options).await {
                Ok(metadata) => match serde_json::to_value(metadata) {
                    Ok(payload) => {
                        if let Some(slot) = session::complete(&task_session_id) {
                            emit_terminal_event(slot, &task_session_id, "metadata-ready", payload);
                        }
                    }
                    Err(err) => {
                        let bridge_error =
                            BridgeError::internal(format!("failed to serialize metadata: {err}"));
                        if let Some(slot) = session::fail(&task_session_id, bridge_error.clone()) {
                            emit_operation_failed(slot, &task_session_id, bridge_error);
                        }
                    }
                },
                Err(err) => {
                    let bridge_error = BridgeError::new("metadata_failed", err.to_string());
                    if let Some(slot) = session::fail(&task_session_id, bridge_error.clone()) {
                        emit_operation_failed(slot, &task_session_id, bridge_error);
                    }
                }
            }
        });

        session::set_abortable_cancel(&session_id, abort_handle);
        Ok(accepted_json(&session_id, "metadata"))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_cancel_operation(request_json: *const c_char) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: SessionRequest = request::parse_request(&request)?;
        let session_id = parsed.validate()?;

        let mut plan = session::cancel(&session_id)?;

        let graceful_receive_cancel = plan
            .cancel_tx
            .take()
            .is_some_and(|cancel_tx| cancel_tx.send(()).is_ok());
        if !graceful_receive_cancel {
            if let Some(abort_handle) = plan.abort_handle.take() {
                abort_handle.abort();
            }
        } else {
            drop(plan.abort_handle.take());
        }

        drop(plan.share_guard.take());

        if !graceful_receive_cancel {
            emit_terminal_event(
                plan.callback,
                &session_id,
                "operation-cancelled",
                json!({ "reason": "cancel requested" }),
            );
        }

        Ok(serialize_ok(json!({
            "cancelled": true,
            "sessionId": session_id,
        })))
    })
}

#[no_mangle]
pub extern "C" fn dashbeam_get_session_status(request_json: *const c_char) -> *mut c_char {
    ffi_boundary(|| {
        let request = unsafe { read_json_request(request_json) }?;
        let parsed: SessionRequest = request::parse_request(&request)?;
        let session_id = parsed.validate()?;

        let status = session::get_snapshot(&session_id).ok_or_else(|| {
            BridgeError::new(
                "session_not_found",
                format!("unknown sessionId: {session_id}"),
            )
        })?;

        Ok(session_status_json(status))
    })
}

fn session_status_json(snapshot: SessionSnapshot) -> String {
    serialize_ok(json!({ "session": snapshot }))
}

/// Returns whether a borrowed response is valid JSON with a boolean `ok` set to true.
#[no_mangle]
pub unsafe extern "C" fn dashbeam_response_is_ok(response_json: *const c_char) -> bool {
    std::panic::catch_unwind(|| {
        if response_json.is_null() {
            return false;
        }

        let Ok(response) = unsafe { CStr::from_ptr(response_json) }.to_str() else {
            return false;
        };
        serde_json::from_str::<serde_json::Value>(response)
            .ok()
            .and_then(|value| value.get("ok").and_then(serde_json::Value::as_bool))
            == Some(true)
    })
    .unwrap_or(false)
}

/// Stops callbacks for an environment-owned context before that context is released.
#[no_mangle]
pub extern "C" fn dashbeam_detach_event_callback(user_data: *mut c_void) {
    let _ = std::panic::catch_unwind(|| events::detach_callback(user_data));
}

/// Releases a string returned by this library. Passing null is allowed.
#[no_mangle]
pub unsafe extern "C" fn dashbeam_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Mutex, OnceLock};

    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    static EVENT_CAPTURE: OnceLock<Mutex<Vec<Value>>> = OnceLock::new();
    static COUNTER: AtomicU64 = AtomicU64::new(1);

    fn serial_guard() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("test lock poisoned")
    }

    fn unique_session_id(prefix: &str) -> String {
        let count = COUNTER.fetch_add(1, Ordering::SeqCst);
        format!("{prefix}-{count}")
    }

    fn read_response(ptr: *mut c_char) -> Value {
        let text = unsafe { CStr::from_ptr(ptr) }
            .to_str()
            .expect("valid utf8")
            .to_string();
        unsafe { dashbeam_free_string(ptr) };
        serde_json::from_str(&text).expect("json response")
    }

    unsafe extern "C" fn capture_callback(
        payload: *const c_char,
        terminal: bool,
        user_data: *mut c_void,
    ) {
        assert!(!payload.is_null());
        assert!(!terminal);
        assert_eq!(user_data as usize, 0x1234);
        let text = unsafe { CStr::from_ptr(payload) }
            .to_str()
            .expect("callback utf8");
        let value: Value = serde_json::from_str(text).expect("callback json");
        EVENT_CAPTURE
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("event capture lock")
            .push(value);
    }

    #[test]
    fn status_reports_linked_abi() {
        let _guard = serial_guard();
        let response = read_response(dashbeam_engine_status());

        assert_eq!(dashbeam_engine_abi_version(), 2);
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["abiVersion"], 2);
        assert_eq!(response["data"]["rustLinked"], true);
    }

    #[test]
    fn invalid_json_is_structured_error() {
        let _guard = serial_guard();
        let request = CString::new("{bad").expect("c string");
        let response = read_response(dashbeam_get_session_status(request.as_ptr()));

        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "invalid_request");
    }

    #[test]
    fn invalid_utf8_is_structured_error() {
        let _guard = serial_guard();
        let bytes: [u8; 2] = [0xff, 0x00];
        let response = read_response(dashbeam_get_session_status(bytes.as_ptr() as *const c_char));

        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "invalid_utf8");
    }

    #[test]
    fn response_ok_helper_parses_the_response_envelope() {
        let ok = CString::new(r#"{"ok":true,"data":{}}"#).expect("c string");
        let error = CString::new(r#"{"ok":false,"error":{}}"#).expect("c string");
        let malformed = CString::new("not json").expect("c string");

        assert!(unsafe { dashbeam_response_is_ok(ok.as_ptr()) });
        assert!(!unsafe { dashbeam_response_is_ok(error.as_ptr()) });
        assert!(!unsafe { dashbeam_response_is_ok(malformed.as_ptr()) });
        assert!(!unsafe { dashbeam_response_is_ok(std::ptr::null()) });
    }

    #[test]
    fn duplicate_session_is_rejected() {
        let _guard = serial_guard();
        let id = unique_session_id("dup");
        let req = json!({
            "sessionId": id,
            "paths": ["C:/definitely-not-a-real-path"],
        });
        let req_text = CString::new(req.to_string()).expect("c string");
        let first = read_response(dashbeam_start_share(
            req_text.as_ptr(),
            None,
            std::ptr::null_mut(),
        ));
        let second = read_response(dashbeam_start_share(
            req_text.as_ptr(),
            None,
            std::ptr::null_mut(),
        ));

        assert_eq!(first["ok"], true);
        assert_eq!(second["ok"], false);
        assert_eq!(second["error"]["code"], "duplicate_session");

        session::remove_session(
            req["sessionId"]
                .as_str()
                .expect("session id should be string"),
        );
    }

    #[test]
    fn unknown_cancel_returns_structured_error() {
        let _guard = serial_guard();
        let req = CString::new(json!({ "sessionId": unique_session_id("missing") }).to_string())
            .expect("c string");
        let response = read_response(dashbeam_cancel_operation(req.as_ptr()));

        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "session_not_found");
    }

    #[test]
    fn session_status_is_queryable() {
        let _guard = serial_guard();
        let session_id = unique_session_id("status");
        let share_req = CString::new(
            json!({
                "sessionId": session_id,
                "paths": ["C:/definitely-not-a-real-path"],
            })
            .to_string(),
        )
        .expect("c string");
        let accepted = read_response(dashbeam_start_share(
            share_req.as_ptr(),
            None,
            std::ptr::null_mut(),
        ));
        assert_eq!(accepted["ok"], true);

        let status_req = CString::new(
            json!({
                "sessionId": accepted["data"]["sessionId"],
            })
            .to_string(),
        )
        .expect("c string");
        let status = read_response(dashbeam_get_session_status(status_req.as_ptr()));
        assert_eq!(status["ok"], true);
        assert_eq!(
            status["data"]["session"]["sessionId"],
            accepted["data"]["sessionId"]
        );

        session::remove_session(
            accepted["data"]["sessionId"]
                .as_str()
                .expect("session id should be string"),
        );
    }

    #[test]
    fn callback_event_envelope_is_valid_json() {
        let _guard = serial_guard();
        EVENT_CAPTURE
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("event capture lock")
            .clear();

        let slot = CallbackSlot::new(Some(capture_callback), 0x1234usize as *mut c_void);
        events::emit_event_for_test(
            slot,
            "s-1",
            "metadata-ready",
            json!({ "ticket": "abc", "size": 10 }),
        );

        let events = EVENT_CAPTURE
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("event capture lock");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["sessionId"], "s-1");
        assert_eq!(events[0]["eventName"], "metadata-ready");
        assert_eq!(events[0]["data"]["ticket"], "abc");
    }

    #[test]
    fn detached_callback_context_receives_no_more_events() {
        let _guard = serial_guard();
        EVENT_CAPTURE
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("event capture lock")
            .clear();

        let session_id = unique_session_id("detached");
        let user_data = 0x1234usize as *mut c_void;
        let slot = CallbackSlot::new(Some(capture_callback), user_data);
        session::insert_session(&session_id, SessionKind::Share, slot.clone())
            .expect("insert session");

        let terminal_slot = session::complete(&session_id).expect("terminal callback slot");

        dashbeam_detach_event_callback(user_data);
        events::emit_event_for_test(terminal_slot, &session_id, "share-ready", json!({}));

        assert!(EVENT_CAPTURE
            .get_or_init(|| Mutex::new(Vec::new()))
            .lock()
            .expect("event capture lock")
            .is_empty());
        session::remove_session(&session_id);
    }
}
