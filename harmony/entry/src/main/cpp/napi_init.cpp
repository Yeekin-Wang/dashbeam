#include <node_api.h>

#include <atomic>
#include <cstdlib>
#include <memory>
#include <new>
#include <string>
#include <vector>

#include <filemanagement/file_uri/oh_file_uri.h>

#include "dashbeam_ohos_bridge.h"
#include "napi_utils.h"

namespace {

struct EventPayload {
  std::string eventJson;
};

struct CallbackContext {
  napi_threadsafe_function tsfn = nullptr;
  std::atomic<uint32_t> references{2};
  std::atomic<bool> rustOwned{true};
  std::atomic<bool> releaseRequested{false};
};

using RustStartFunction = char *(*)(const char *, dashbeam_event_callback_t,
                                    void *);
using RustStringFunction = char *(*)(const char *);
using RustNoArgStringFunction = char *(*)();

void ReleaseContextReference(CallbackContext *context) {
  if (context->references.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    delete context;
  }
}

void ReleaseRustOwnership(CallbackContext *context) {
  bool expected = true;
  if (context->rustOwned.compare_exchange_strong(expected, false,
                                                 std::memory_order_acq_rel)) {
    ReleaseContextReference(context);
  }
}

napi_status RequestTsfnRelease(CallbackContext *context,
                               napi_threadsafe_function_release_mode mode) {
  bool expected = false;
  if (!context->releaseRequested.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel)) {
    return napi_ok;
  }
  return napi_release_threadsafe_function(context->tsfn, mode);
}

void CloseCallbackContext(CallbackContext *context,
                          napi_threadsafe_function_release_mode mode) {
  dashbeam_detach_event_callback(context);
  ReleaseRustOwnership(context);
  (void)RequestTsfnRelease(context, mode);
}

void FinalizeCallbackContext(napi_env env, void *finalizeData,
                             void *finalizeHint) {
  (void)env;
  (void)finalizeHint;
  auto *context = static_cast<CallbackContext *>(finalizeData);
  if (context == nullptr) {
    return;
  }

  context->releaseRequested.store(true, std::memory_order_release);
  dashbeam_detach_event_callback(context);
  ReleaseRustOwnership(context);
  ReleaseContextReference(context);
}

void CallArkTsCallback(napi_env env, napi_value callback, void *context,
                       void *data) {
  (void)context;
  std::unique_ptr<EventPayload> payload(static_cast<EventPayload *>(data));
  if (payload == nullptr || env == nullptr || callback == nullptr) {
    return;
  }

  napi_value receiver = nullptr;
  if (napi_get_undefined(env, &receiver) != napi_ok) {
    return;
  }

  napi_value argument = nullptr;
  if (napi_create_string_utf8(env, payload->eventJson.data(),
                              payload->eventJson.size(),
                              &argument) != napi_ok) {
    return;
  }

  const napi_status status =
      napi_call_function(env, receiver, callback, 1, &argument, nullptr);
  if (status != napi_ok && status != napi_pending_exception) {
    (void)ThrowNapiError(env, "napi_call_function", status);
  }
}

void RustEventCallback(const char *eventJson, bool terminal,
                       void *userData) noexcept {
  auto *context = static_cast<CallbackContext *>(userData);
  if (context == nullptr) {
    return;
  }

  if (!context->releaseRequested.load(std::memory_order_acquire) &&
      eventJson != nullptr) {
    EventPayload *payload = nullptr;
    try {
      payload = new EventPayload{std::string(eventJson)};
    } catch (...) {
      (void)RequestTsfnRelease(context, napi_tsfn_abort);
    }

    if (payload != nullptr) {
      const napi_status status = napi_call_threadsafe_function(
          context->tsfn, payload, napi_tsfn_nonblocking);
      if (status != napi_ok) {
        delete payload;
        (void)RequestTsfnRelease(context, napi_tsfn_abort);
      }
    }
  } else if (eventJson == nullptr) {
    (void)RequestTsfnRelease(context, napi_tsfn_abort);
  }

  if (terminal) {
    (void)RequestTsfnRelease(context, napi_tsfn_release);
    ReleaseRustOwnership(context);
  }
}

bool ReadUtf8String(napi_env env, napi_value value, const char *argumentName,
                    std::string &result) {
  napi_valuetype valueType = napi_undefined;
  napi_status status = napi_typeof(env, value, &valueType);
  if (status != napi_ok) {
    (void)ThrowNapiError(env, "napi_typeof", status);
    return false;
  }
  if (valueType != napi_string) {
    std::string message(argumentName);
    message.append(" must be a string");
    (void)ThrowTypeError(env, message.c_str());
    return false;
  }

  size_t length = 0;
  status = napi_get_value_string_utf8(env, value, nullptr, 0, &length);
  if (status != napi_ok) {
    (void)ThrowNapiError(env, "napi_get_value_string_utf8", status);
    return false;
  }

  try {
    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    status = napi_get_value_string_utf8(env, value, buffer.data(),
                                        buffer.size(), &copied);
    if (status != napi_ok) {
      (void)ThrowNapiError(env, "napi_get_value_string_utf8", status);
      return false;
    }
    result.assign(buffer.data(), copied);
  } catch (...) {
    napi_throw_error(env, nullptr, "failed to allocate request string");
    return false;
  }

  if (result.find('\0') != std::string::npos) {
    (void)ThrowTypeError(env, "requestJson must not contain null bytes");
    return false;
  }
  return true;
}

bool ReadArguments(napi_env env, napi_callback_info info, size_t expectedCount,
                   napi_value *arguments) {
  size_t argumentCount = expectedCount;
  const napi_status status =
      napi_get_cb_info(env, info, &argumentCount, arguments, nullptr, nullptr);
  if (status != napi_ok) {
    (void)ThrowNapiError(env, "napi_get_cb_info", status);
    return false;
  }
  if (argumentCount < expectedCount) {
    (void)ThrowTypeError(env, "missing required argument");
    return false;
  }
  return true;
}

bool CopyAndFreeRustString(napi_env env, char *rustString,
                           std::string &result) {
  if (rustString == nullptr) {
    napi_throw_error(env, nullptr, "Rust bridge returned a null response");
    return false;
  }

  try {
    result.assign(rustString);
  } catch (...) {
    dashbeam_free_string(rustString);
    napi_throw_error(env, nullptr, "failed to copy Rust bridge response");
    return false;
  }
  dashbeam_free_string(rustString);
  return true;
}

static napi_value AbiVersion(napi_env env, napi_callback_info info) {
  (void)info;
  return CreateInt32(env, static_cast<int32_t>(dashbeam_engine_abi_version()));
}

static napi_value BridgeStatus(napi_env env, napi_callback_info info) {
  (void)info;
  std::string status;
  if (!CopyAndFreeRustString(env, dashbeam_engine_status(), status)) {
    return GetUndefined(env);
  }
  if (!dashbeam_response_is_ok(status.c_str())) {
    napi_throw_error(env, nullptr, "Rust bridge status response is invalid");
    return GetUndefined(env);
  }
  return CreateString(env, "native-ready-rust-linked");
}

static napi_value IsRustLinked(napi_env env, napi_callback_info info) {
  (void)info;
  std::string status;
  if (!CopyAndFreeRustString(env, dashbeam_engine_status(), status)) {
    return GetUndefined(env);
  }
  return CreateBoolean(env, dashbeam_response_is_ok(status.c_str()));
}

static napi_value StartOperation(napi_env env, napi_callback_info info,
                                 RustStartFunction startFunction,
                                 const char *resourceName) {
  napi_value arguments[2] = {nullptr, nullptr};
  if (!ReadArguments(env, info, 2, arguments)) {
    return GetUndefined(env);
  }

  std::string requestJson;
  if (!ReadUtf8String(env, arguments[0], "requestJson", requestJson)) {
    return GetUndefined(env);
  }

  napi_valuetype callbackType = napi_undefined;
  napi_status status = napi_typeof(env, arguments[1], &callbackType);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_typeof", status);
  }
  if (callbackType != napi_function) {
    return ThrowTypeError(env, "callback must be a function");
  }

  auto *context = new (std::nothrow) CallbackContext();
  if (context == nullptr) {
    napi_throw_error(env, nullptr, "failed to allocate callback context");
    return GetUndefined(env);
  }

  napi_value asyncResourceName = nullptr;
  status = napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH,
                                   &asyncResourceName);
  if (status != napi_ok) {
    delete context;
    return ThrowNapiError(env, "napi_create_string_utf8", status);
  }

  status = napi_create_threadsafe_function(
      env, arguments[1], nullptr, asyncResourceName, 0, 1, context,
      FinalizeCallbackContext, context, CallArkTsCallback, &context->tsfn);
  if (status != napi_ok) {
    delete context;
    return ThrowNapiError(env, "napi_create_threadsafe_function", status);
  }

  status = napi_unref_threadsafe_function(env, context->tsfn);
  if (status != napi_ok) {
    CloseCallbackContext(context, napi_tsfn_abort);
    return ThrowNapiError(env, "napi_unref_threadsafe_function", status);
  }

  std::string response;
  if (!CopyAndFreeRustString(
          env, startFunction(requestJson.c_str(), RustEventCallback, context),
          response)) {
    CloseCallbackContext(context, napi_tsfn_abort);
    return GetUndefined(env);
  }

  if (!dashbeam_response_is_ok(response.c_str())) {
    CloseCallbackContext(context, napi_tsfn_release);
  }
  return CreateString(env, response);
}

static napi_value StartShare(napi_env env, napi_callback_info info) {
  return StartOperation(env, info, dashbeam_start_share, "DashBeam startShare");
}

static napi_value StartReceive(napi_env env, napi_callback_info info) {
  return StartOperation(env, info, dashbeam_start_receive,
                        "DashBeam startReceive");
}

static napi_value FetchMetadata(napi_env env, napi_callback_info info) {
  return StartOperation(env, info, dashbeam_fetch_metadata,
                        "DashBeam fetchMetadata");
}

static napi_value StartNode(napi_env env, napi_callback_info info) {
  return StartOperation(env, info, dashbeam_start_node, "DashBeam startNode");
}

static napi_value NodeCommand(napi_env env, napi_callback_info info) {
  return StartOperation(env, info, dashbeam_node_command,
                        "DashBeam nodeCommand");
}

static napi_value CallStringOperation(napi_env env, napi_callback_info info,
                                      RustStringFunction operation) {
  napi_value argument = nullptr;
  if (!ReadArguments(env, info, 1, &argument)) {
    return GetUndefined(env);
  }

  std::string requestJson;
  if (!ReadUtf8String(env, argument, "requestJson", requestJson)) {
    return GetUndefined(env);
  }

  std::string response;
  if (!CopyAndFreeRustString(env, operation(requestJson.c_str()), response)) {
    return GetUndefined(env);
  }
  return CreateString(env, response);
}

static napi_value CancelOperation(napi_env env, napi_callback_info info) {
  return CallStringOperation(env, info, dashbeam_cancel_operation);
}

static napi_value GetSessionStatus(napi_env env, napi_callback_info info) {
  return CallStringOperation(env, info, dashbeam_get_session_status);
}

static napi_value StopNode(napi_env env, napi_callback_info info) {
  return CallStringOperation(env, info, dashbeam_stop_node);
}

static napi_value NodeStatus(napi_env env, napi_callback_info info) {
  (void)info;
  std::string response;
  if (!CopyAndFreeRustString(env, dashbeam_node_status(), response)) {
    return GetUndefined(env);
  }
  return CreateString(env, response);
}

static napi_value ResolveFileUri(napi_env env, napi_callback_info info) {
  napi_value argument = nullptr;
  if (!ReadArguments(env, info, 1, &argument)) {
    return GetUndefined(env);
  }

  std::string uri;
  if (!ReadUtf8String(env, argument, "uri", uri)) {
    return GetUndefined(env);
  }

  char *resolvedPath = nullptr;
  const FileManagement_ErrCode result = OH_FileUri_GetPathFromUri(
      uri.c_str(), static_cast<unsigned int>(uri.size()), &resolvedPath);
  if (result != 0 || resolvedPath == nullptr) {
    std::free(resolvedPath);
    const std::string message =
        "failed to resolve file URI, code " + std::to_string(result);
    napi_throw_error(env, nullptr, message.c_str());
    return GetUndefined(env);
  }

  std::string path;
  try {
    path.assign(resolvedPath);
  } catch (...) {
    std::free(resolvedPath);
    napi_throw_error(env, nullptr, "failed to copy resolved file URI path");
    return GetUndefined(env);
  }
  std::free(resolvedPath);
  return CreateString(env, path);
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
      {"abiVersion", nullptr, AbiVersion, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"bridgeStatus", nullptr, BridgeStatus, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"isRustLinked", nullptr, IsRustLinked, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"startShare", nullptr, StartShare, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"startReceive", nullptr, StartReceive, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"fetchMetadata", nullptr, FetchMetadata, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"startNode", nullptr, StartNode, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"stopNode", nullptr, StopNode, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"nodeCommand", nullptr, NodeCommand, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"nodeStatus", nullptr, NodeStatus, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"cancelOperation", nullptr, CancelOperation, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"getSessionStatus", nullptr, GetSessionStatus, nullptr, nullptr, nullptr,
        napi_default, nullptr},
            {"resolveFileUri", nullptr, ResolveFileUri, nullptr, nullptr, nullptr,
       napi_default, nullptr}};

  const napi_status status = napi_define_properties(
      env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_define_properties", status);
  }
  return exports;
}

} // namespace

EXTERN_C_START
static napi_module dashbeamEngineModule = {.nm_version = 1,
                                           .nm_flags = 0,
                                           .nm_filename = nullptr,
                                           .nm_register_func = Init,
                                           .nm_modname = "dashbeam_engine",
                                           .nm_priv = nullptr,
                                           .reserved = {0}};
EXTERN_C_END

extern "C" __attribute__((constructor)) void
RegisterDashbeamEngineModule(void) {
  napi_module_register(&dashbeamEngineModule);
}