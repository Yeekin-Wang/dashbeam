#ifndef DASHBEAM_OHOS_BRIDGE_H
#define DASHBEAM_OHOS_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Event callback used by asynchronous session operations.
 *
 * - event_json points to a UTF-8 JSON envelope:
 * {"sessionId","eventName","data"}
 * - event_json is borrowed and valid only for the duration of this callback
 * call.
 * - Do not store event_json after the callback returns.
 * - terminal is true only for the final event. No further callbacks will
 * follow.
 * - user_data is the opaque pointer passed when starting the session.
 */
typedef void (*dashbeam_event_callback_t)(const char *event_json, bool terminal,
                                          void *user_data);

/** Returns bridge ABI version (currently 2; NodeService is an additive API). */
uint32_t dashbeam_engine_abi_version(void);

/**
 * Returns UTF-8 JSON status.
 *
 * Ownership: caller must release the returned pointer with
 * dashbeam_free_string.
 */
char *dashbeam_engine_status(void);

/**
 * Starts the single process-wide NodeService asynchronously.
 *
 * request_json schema:
 * {
 *   "sessionId": "string",                 // required, non-empty
 *   "dataDir": "/absolute/sandbox/path",   // required; never file://
 *   "displayName": "My device",            // optional
 *   "deviceType": "phone" | "tablet" | "foldable" | "widefold" |
 *                 "triplefold" | "2in1" | "unknown", // optional
 *   "discoverability": "everyone" | "paired-only" | "off" // required
 * }
 *
 * The service uses the engine's default relay and discovery configuration.
 * displayName and deviceType are persisted before node-ready. A duplicate
 * start returns an error with code=node_already_started.
 *
 * Returns immediate accepted/error JSON:
 * {"ok":true,"data":{"accepted":true,"sessionId":"...",
 *                     "operation":"startNode"}}
 * Ownership: caller must release with dashbeam_free_string.
 *
 * callback is long-lived. Non-terminal events include:
 * - node-ready with data.deviceInfo and data.networkReady
 * - every native NodeService AppHandle event, preserving a JSON payload as
 *   JSON and forwarding a non-JSON payload as a string
 *
 * callback becomes terminal only when:
 * - node-stopped is emitted after shutdown has actually completed (its data
 *   may contain an error when shutdown failed), or
 * - operation-failed is emitted for a fatal start/lifecycle failure
 *
 * user_data must remain valid through that terminal callback, or until
 * dashbeam_detach_event_callback(user_data) returns.
 */
char *dashbeam_start_node(const char *request_json,
                          dashbeam_event_callback_t callback, void *user_data);

/**
 * Requests asynchronous shutdown of the process-wide NodeService.
 *
 * request_json schema:
 * { "sessionId": "the active node session id" }
 *
 * Running transitions immediately to stopping and performs shutdown outside
 * the manager mutex. Starting records stopRequested and shuts down as soon as
 * startup lands. Stopped and Stopping return successful idempotent status.
 * A different active sessionId returns code=node_session_mismatch.
 *
 * Returns immediate accepted/error JSON. This function has no callback; the
 * terminal node-stopped event is delivered to the callback originally passed
 * to dashbeam_start_node, and only after real shutdown or shutdown failure.
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_stop_node(const char *request_json);

/**
 * Executes one command against a ready process-wide NodeService.
 *
 * Every request contains {"sessionId":"...","operation":"..."}. The
 * complete operation-specific request union is:
 *
 * {"sessionId":"...","operation":"getDeviceInfo"}
 * {"sessionId":"...","operation":"listPaired"}
 * {"sessionId":"...","operation":"listNearby"}
 * {"sessionId":"...","operation":"startPairingHost","ttlSecs":60}
 *     // ttlSecs is optional
 * {"sessionId":"...","operation":"stopPairingHost"}
 * {"sessionId":"...","operation":"joinPairing","ticket":"..."}
 * {"sessionId":"...","operation":"forgetPaired","endpointId":"..."}
 * {"sessionId":"...","operation":"requestNearbyPair",
 *  "endpointId":"..."}
 * {"sessionId":"...","operation":"respondNearbyInvite",
 *  "endpointId":"...","accept":true,"block":false}
 * {"sessionId":"...","operation":"renameDevice",
 *  "displayName":"..."}
 * {"sessionId":"...","operation":"renamePaired","endpointId":"...",
 *  "displayName":"..."}
 * {"sessionId":"...","operation":"setDiscoverability",
 *  "discoverability":"everyone" | "paired-only" | "off"}
 * {"sessionId":"...","operation":"invitePaired","endpointId":"...",
 *  "blobTicket":"...","fileCount":1,"totalSize":123}
 * {"sessionId":"...","operation":"inviteNearby","endpointId":"...",
 *  "blobTicket":"...","fileCount":1,"totalSize":123}
 * {"sessionId":"...","operation":"respondPairedInvite",
 *  "endpointId":"...","accept":true}
 *
 * Missing operation fields return an immediate code=invalid_request error.
 * Commands are accepted only while status=ready. sessionId is the correlation
 * id for this one command and is returned in its callback envelope; it need
 * not equal the long-lived node sessionId.
 *
 * Returns immediate accepted/error JSON. For an accepted command, callback is
 * one-shot and always terminal=true:
 * - node-command-completed with data {"operation":"...","result":...}
 * - operation-failed with data {"operation":"...","code":"...",
 *   "message":"..."}
 *
 * user_data must remain valid through that terminal callback, or until
 * dashbeam_detach_event_callback(user_data) returns. Ownership of the returned
 * immediate JSON belongs to the caller and must be released with
 * dashbeam_free_string.
 */
char *dashbeam_node_command(const char *request_json,
                            dashbeam_event_callback_t callback,
                            void *user_data);

/**
 * Returns synchronous process-wide node status JSON.
 *
 * The response envelope is {"ok":true,"data":...}. data.status is one of:
 * - {"status":"stopped"}
 * - {"status":"starting","sessionId":"...","stopRequested":bool}
 * - {"status":"ready","sessionId":"...","networkReady":bool,
 *    "deviceInfo":{...}}
 * - {"status":"stopping","sessionId":"..."}
 *
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_node_status(void);

/**
 * Starts a share session asynchronously.
 *
 * request_json schema:
 * {
 *   "sessionId": "string",
 *   "paths": ["/real/sandbox/path"],
 *   "metadata": { ... optional FileMetadata ... },
 *   "relayMode": "default" | "disabled",               // optional,
 * default=default "ticketType": "id" | "relayAndAddresses" | "relay" |
 * "addresses" // optional
 * }
 *
 * Not supported yet:
 * - custom relay/discovery options.
 *
 * Returns immediate accepted/error JSON.
 * Ownership: caller must release with dashbeam_free_string.
 *
 * Lifetime: if callback is non-null, ensure user_data remains valid until a
 * terminal event is emitted for this session (operation-failed /
 * operation-cancelled, or receive-completed for receive sessions,
 * metadata-ready for metadata sessions).
 */
char *dashbeam_start_share(const char *request_json,
                           dashbeam_event_callback_t callback, void *user_data);

/**
 * Starts a receive session asynchronously.
 *
 * request_json schema:
 * {
 *   "sessionId": "string",
 *   "ticket": "string",
 *   "outputDir": "/real/sandbox/output/path",
 *   "relayMode": "default" | "disabled" // optional, default=default
 * }
 *
 * Returns immediate accepted/error JSON.
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_start_receive(const char *request_json,
                             dashbeam_event_callback_t callback,
                             void *user_data);

/**
 * Starts an asynchronous metadata fetch session.
 *
 * request_json schema:
 * {
 *   "sessionId": "string",
 *   "ticket": "string",
 *   "relayMode": "default" | "disabled" // optional, default=default
 * }
 *
 * Returns immediate accepted/error JSON.
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_fetch_metadata(const char *request_json,
                              dashbeam_event_callback_t callback,
                              void *user_data);

/**
 * Cancels a session by sessionId.
 *
 * request_json schema:
 * { "sessionId": "string" }
 *
 * Returns JSON with cancellation result or structured error.
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_cancel_operation(const char *request_json);

/**
 * Queries session state by sessionId.
 *
 * request_json schema:
 * { "sessionId": "string" }
 *
 * Returns JSON with stable serializable session state.
 * Ownership: caller must release with dashbeam_free_string.
 */
char *dashbeam_get_session_status(const char *request_json);

/**
 * Returns true only when response_json is a valid bridge response with ok=true.
 * The input is borrowed for the duration of this call.
 */
bool dashbeam_response_is_ok(const char *response_json);

/**
 * Detaches callbacks associated with user_data and waits for any in-flight
 * callback using it to return. Intended for host environment shutdown.
 */
void dashbeam_detach_event_callback(void *user_data);

/**
 * Releases a string returned by this library. Passing NULL is allowed.
 */
void dashbeam_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
