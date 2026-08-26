#ifndef DASHBEAM_ENGINE_NAPI_UTILS_H
#define DASHBEAM_ENGINE_NAPI_UTILS_H

#include <node_api.h>

#include <string>

inline napi_value GetUndefined(napi_env env) {
  napi_value result = nullptr;
  return napi_get_undefined(env, &result) == napi_ok ? result : nullptr;
}

inline napi_value ThrowTypeError(napi_env env, const char *message) {
  napi_throw_type_error(env, nullptr, message);
  return GetUndefined(env);
}

inline napi_value ThrowNapiError(napi_env env, const char *operation,
                                 napi_status status) {
  if (status == napi_pending_exception) {
    return nullptr;
  }

  std::string message(operation);
  const napi_extended_error_info *errorInfo = nullptr;
  if (napi_get_last_error_info(env, &errorInfo) == napi_ok &&
      errorInfo != nullptr && errorInfo->error_message != nullptr) {
    message.append(": ").append(errorInfo->error_message);
  }
  napi_throw_error(env, nullptr, message.c_str());
  return GetUndefined(env);
}

inline napi_value CreateInt32(napi_env env, int32_t value) {
  napi_value result = nullptr;
  const napi_status status = napi_create_int32(env, value, &result);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_create_int32", status);
  }
  return result;
}

inline napi_value CreateBoolean(napi_env env, bool value) {
  napi_value result = nullptr;
  const napi_status status = napi_get_boolean(env, value, &result);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_get_boolean", status);
  }
  return result;
}

inline napi_value CreateString(napi_env env, const char *value) {
  napi_value result = nullptr;
  const napi_status status =
      napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_create_string_utf8", status);
  }
  return result;
}

inline napi_value CreateString(napi_env env, const std::string &value) {
  napi_value result = nullptr;
  const napi_status status =
      napi_create_string_utf8(env, value.data(), value.size(), &result);
  if (status != napi_ok) {
    return ThrowNapiError(env, "napi_create_string_utf8", status);
  }
  return result;
}

#endif