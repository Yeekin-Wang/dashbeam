export enum NavSection {
  SEND = 'send',
  RECEIVE = 'receive',
  DEVICES = 'devices',
  HISTORY = 'history',
  SETTINGS = 'settings'
}

export enum TransferStage {
  IDLE = 'idle',
  SELECTED = 'selected',
  SHARING = 'sharing',
  RECEIVING = 'receiving',
  COMPLETED = 'completed',
  CANCELLED = 'cancelled',
  ERROR = 'error'
}

export enum EngineAvailability {
  AVAILABLE = 'available',
  UNAVAILABLE = 'unavailable',
  STARTING = 'starting'
}

export class TransferItem {
  id: string = ''
  uri: string = ''
  name: string = ''
  kind: string = 'file'
  sizeLabel: string = ''
}

export class TransferProgress {
  transferId: string = ''
  stage: TransferStage = TransferStage.IDLE
  title: string = ''
  detail: string = ''
  ticket: string = ''
  progressRatio: number = 0
  itemCount: number = 0
  totalBytes: number = 0
  bytesLabel: string = ''
  speedLabel: string = ''
  errorMessage: string = ''
}

export class FilePreviewMetadata {
  fileName: string = ''
  size: number = 0
}

export class TransferMetadata {
  fileName: string = ''
  itemCount: number = 0
  size: number = 0
  items: Array<FilePreviewMetadata> = []
}

export class PairedDevice {
  id: string = ''
  name: string = ''
  deviceType: string = ''
  os: string = ''
  pairingStatus: string = ''
  online: boolean = false
  status: string = ''
  lastSeen: string = ''
}

export class NearbyDevice {
  id: string = ''
  name: string = ''
  deviceType: string = ''
  os: string = ''
  fingerprint: string = ''
  identified: boolean = false
  signalLabel: string = ''
  status: string = ''
}

export class NodeSnapshot {
  status: string = 'stopped'
  message: string = '设备节点尚未启动。'
  networkReady: boolean = false
  endpointId: string = ''
  deviceName: string = ''
  deviceType: string = ''
  pairingTicket: string = ''

  clone(): NodeSnapshot {
    let next: NodeSnapshot = new NodeSnapshot()
    next.status = this.status
    next.message = this.message
    next.networkReady = this.networkReady
    next.endpointId = this.endpointId
    next.deviceName = this.deviceName
    next.deviceType = this.deviceType
    next.pairingTicket = this.pairingTicket
    return next
  }
}

export class NearbyPairRequest {
  endpointId: string = ''
  senderName: string = ''
  deviceType: string = ''
  os: string = ''
}

export class IncomingTransferInvite {
  endpointId: string = ''
  senderName: string = ''
  ticket: string = ''
  fileCount: number = 0
  totalSize: number = 0
  paired: boolean = false
}

export class HistoryEntry {
  id: string = ''
  direction: string = ''
  title: string = ''
  detail: string = ''
  timestamp: string = ''
  status: string = ''
}

export class AppSettings {
  deviceName: string = 'DashBeam Harmony'
  theme: string = '跟随系统'
  discoverable: boolean = true
  defaultRelay: string = ''
  defaultDiscovery: string = ''
  dnsOrigin: string = ''
  resumeInBackground: boolean = true
  about: string = 'DashBeam HarmonyOS 应用壳 0.7.0'

  clone(): AppSettings {
    let next: AppSettings = new AppSettings()
    next.deviceName = this.deviceName
    next.theme = this.theme
    next.discoverable = this.discoverable
    next.defaultRelay = this.defaultRelay
    next.defaultDiscovery = this.defaultDiscovery
    next.dnsOrigin = this.dnsOrigin
    next.resumeInBackground = this.resumeInBackground
    next.about = this.about
    return next
  }
}

export class EngineSnapshot {
  availability: EngineAvailability = EngineAvailability.UNAVAILABLE
  message: string = '正在读取 HarmonyOS 原生传输引擎状态。'
}

export class NativeBridgeStatus {
  abiVersion: number = 0
  bridgeStatus: string = 'native-unavailable'
  rustLinked: boolean = false
}

export class DisplayState {
  isFoldable: boolean = false
  foldStatus: string = '不可折叠或不可用'
  width: number = 0
  height: number = 0
  rotation: number = 0
}