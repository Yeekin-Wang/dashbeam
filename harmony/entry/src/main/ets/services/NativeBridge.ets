import nativeEngine from 'libdashbeam_engine.so'
import { NativeBridgeStatus } from '../models/AppModels'

export type NativeEventCallback = (eventJson: string) => void

export class NativeBridge {
  getStatus(): NativeBridgeStatus {
    let status: NativeBridgeStatus = new NativeBridgeStatus()
    status.abiVersion = nativeEngine.abiVersion()
    status.bridgeStatus = nativeEngine.bridgeStatus()
    status.rustLinked = nativeEngine.isRustLinked()
    return status
  }

  startShare(requestJson: string, callback: NativeEventCallback): string {
    return nativeEngine.startShare(requestJson, callback)
  }

  startReceive(requestJson: string, callback: NativeEventCallback): string {
    return nativeEngine.startReceive(requestJson, callback)
  }

  fetchMetadata(requestJson: string, callback: NativeEventCallback): string {
    return nativeEngine.fetchMetadata(requestJson, callback)
  }

  startNode(requestJson: string, callback: NativeEventCallback): string {
    return nativeEngine.startNode(requestJson, callback)
  }

  stopNode(requestJson: string): string {
    return nativeEngine.stopNode(requestJson)
  }

  nodeCommand(requestJson: string, callback: NativeEventCallback): string {
    return nativeEngine.nodeCommand(requestJson, callback)
  }

  nodeStatus(): string {
    return nativeEngine.nodeStatus()
  }

  cancelOperation(requestJson: string): string {
    return nativeEngine.cancelOperation(requestJson)
  }

  getSessionStatus(requestJson: string): string {
    return nativeEngine.getSessionStatus(requestJson)
  }

  resolveFileUri(uri: string): string {
    return nativeEngine.resolveFileUri(uri)
  }
}

export const nativeBridge: NativeBridge = new NativeBridge()