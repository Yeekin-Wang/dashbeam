import {
  AppSettings,
  EngineAvailability,
  EngineSnapshot,
  FilePreviewMetadata,
  HistoryEntry,
  IncomingTransferInvite,
  NativeBridgeStatus,
  NearbyDevice,
  NearbyPairRequest,
  NodeSnapshot,
  PairedDevice,
  TransferItem,
  TransferMetadata,
  TransferProgress,
  TransferStage
} from '../models/AppModels'
import { nativeBridge } from './NativeBridge'
import { platformService } from './PlatformService'
import { systemIntegrationService } from './SystemIntegrationService'

const HISTORY_LIMIT: number = 100

interface NativeErrorData {
  code: string
  message: string
}

interface NativeStartData {
  accepted: boolean
  sessionId: string
  operation: string
}

interface NativeStartResponse {
  ok: boolean
  data?: NativeStartData
  error?: NativeErrorData
}

interface NativeBasicResponse {
  ok: boolean
  error?: NativeErrorData
}

interface NativeCancelRequest {
  sessionId: string
}

interface NativeShareMetadataItem {
  file_name: string
  size: number
}

interface NativeShareMetadata {
  file_name: string
  item_count: number
  size: number
  items: Array<NativeShareMetadataItem>
}

interface NativeDiscoveryConfig {
  mode: string
  pkarr_relay_url: string
  dns_origin?: string
}

interface NativeNetworkConfig {
  relayMode: string
  relayUrls?: Array<string>
  discoveryMode?: NativeDiscoveryConfig
}

interface NativeShareRequest extends NativeNetworkConfig {
  sessionId: string
  paths: Array<string>
  metadata: NativeShareMetadata
  ticketType: string
}

interface NativeReceiveRequest extends NativeNetworkConfig {
  sessionId: string
  ticket: string
  outputDir: string
}

interface NativeMetadataRequest extends NativeNetworkConfig {
  sessionId: string
  ticket: string
}

interface NativeEventHeader {
  sessionId: string
  eventName: string
}

interface NativeShareReadyData {
  ticket: string
  hash: string
  size: number
  entryType: string
}

interface NativeShareReadyEvent {
  sessionId: string
  eventName: string
  data: NativeShareReadyData
}

interface NativeProgressEvent {
  sessionId: string
  eventName: string
  data: string
}

interface NativeStringArrayEvent {
  sessionId: string
  eventName: string
  data: Array<string>
}

interface NativeConflictData {
  original: string
  resolved: string
}

interface NativeConflictEvent {
  sessionId: string
  eventName: string
  data: Array<NativeConflictData>
}

interface NativeTransferCompletedData {
  message?: string
  filePath?: string
}

interface NativeTransferCompletedEvent {
  sessionId: string
  eventName: string
  data: NativeTransferCompletedData
}

interface NativeErrorEvent {
  sessionId: string
  eventName: string
  data: NativeErrorData
}

interface NativeMetadataItemData {
  file_name: string
  size: number
}

interface NativeMetadataData {
  file_name: string
  item_count: number
  size: number
  items?: Array<NativeMetadataItemData>
}

interface NativeMetadataReadyEvent {
  sessionId: string
  eventName: string
  data: NativeMetadataData
}

interface NativeNodeDeviceInfo {
  endpoint_id: string
  display_name: string
  device_type: string
  os: string
}

interface NativeNodeStartRequest extends NativeNetworkConfig {
  sessionId: string
  dataDir: string
  displayName: string
  deviceType: string
  discoverability: string
}

interface NativeNodeStatusData {
  status: string
  sessionId?: string
  stopRequested?: boolean
  networkReady?: boolean
  deviceInfo?: NativeNodeDeviceInfo
  nearbyUnavailableReason?: string | null
}

interface NativeNodeStatusResponse {
  ok: boolean
  data?: NativeNodeStatusData
  error?: NativeErrorData
}

interface NativeNodeCommandRequest {
  sessionId: string
  operation: string
  ttlSecs?: number
  ticket?: string
  endpointId?: string
  accept?: boolean
  block?: boolean
  displayName?: string
  discoverability?: string
  blobTicket?: string
  fileCount?: number
  totalSize?: number
}

interface NativeNodeCommandData {
  operation: string
  result: Object
}

interface NativeNodeCommandEvent {
  sessionId: string
  eventName: string
  data: NativeNodeCommandData
}

interface NativeNodeReadyData {
  deviceInfo: NativeNodeDeviceInfo
  networkReady: boolean
  nearbyUnavailableReason?: string | null
}

interface NativeNodeReadyEvent {
  sessionId: string
  eventName: string
  data: NativeNodeReadyData
}

interface NativePairedDeviceData {
  endpoint_id: string
  display_name: string
  device_type: string
  os: string
  paired_at: number
  last_seen_at: number
  pairing_status: string
  online: boolean
}

interface NativeNearbyDeviceData {
  endpointId: string
  fingerprint: string
  displayName?: string
  deviceType?: string
  os?: string
  identified: boolean
}

interface NativePairDeliveryResult {
  delivered: boolean
}

interface NativePairingHostResult {
  ticket: string
}

interface NativeNearbyPairRequestData {
  remote_endpoint_id: string
  sender_name: string
  device_type: string
  os: string
}

interface NativeNearbyPairRequestEvent {
  sessionId: string
  eventName: string
  data: NativeNearbyPairRequestData
}

interface NativeTransferInviteData {
  blob_ticket: string
  file_count: number
  total_size: number
  sender_name: string
  remote_endpoint_id: string
}

interface NativeTransferInviteEvent {
  sessionId: string
  eventName: string
  data: NativeTransferInviteData
}

interface NativeNearbyUnavailableData {
  reason: string
}

interface NativeNearbyUnavailableEvent {
  sessionId: string
  eventName: string
  data: NativeNearbyUnavailableData
}

class TransferRuntime {
  progress: TransferProgress = new TransferProgress()
  fileNames: Array<string> = []
  terminal: boolean = false
}

export type TransferProgressCallback = (progress: TransferProgress) => void
export type MetadataCallback = (metadata: TransferMetadata | null, errorMessage: string) => void

export interface EngineListener {
  onAvailabilityChanged(snapshot: EngineSnapshot): void
}

export interface NodeListener {
  onNodeChanged(snapshot: NodeSnapshot): void
  onDevicesChanged(paired: Array<PairedDevice>, nearby: Array<NearbyDevice>): void
  onNearbyPairRequest(request: NearbyPairRequest): void
  onTransferInvite(invite: IncomingTransferInvite): void
}

export class EngineService {
  private listeners: Array<EngineListener> = []
  private nodeListeners: Array<NodeListener> = []
  private transferDirectories: Map<string, string> = new Map<string, string>()
  private sessionSequence: number = 0
  private nodeSessionId: string = ''
  private nodeSnapshot: NodeSnapshot = new NodeSnapshot()
  private pairedDevices: Array<PairedDevice> = []
  private nearbyDevices: Array<NearbyDevice> = []
  private nodeStartInFlight: boolean = false
  private deviceRefreshInFlight: boolean = false
  private deviceRefreshPending: boolean = false

  private networkConfig(settings: AppSettings): NativeNetworkConfig {
    let relayUrl: string = settings.defaultRelay.trim()
    let discoveryUrl: string = settings.defaultDiscovery.trim()
    let dnsOrigin: string = settings.dnsOrigin.trim()
    if (dnsOrigin.length > 0 && discoveryUrl.length === 0) {
      throw new Error('DNS Origin 需要同时填写自定义 Discovery URL。')
    }
    let config: NativeNetworkConfig = { relayMode: relayUrl.length > 0 ? 'custom' : 'default' }
    if (relayUrl.length > 0) {
      config.relayUrls = [relayUrl]
    }
    if (discoveryUrl.length > 0) {
      let discovery: NativeDiscoveryConfig = { mode: 'custom', pkarr_relay_url: discoveryUrl }
      if (dnsOrigin.length > 0) {
        discovery.dns_origin = dnsOrigin
      }
      config.discoveryMode = discovery
    }
    return config
  }

  getAvailability(): EngineSnapshot {
    let snapshot: EngineSnapshot = new EngineSnapshot()
    let bridge: NativeBridgeStatus = nativeBridge.getStatus()
    if (bridge.rustLinked && bridge.abiVersion === 2 && bridge.bridgeStatus === 'native-ready-rust-linked') {
      snapshot.availability = EngineAvailability.AVAILABLE
      snapshot.message = 'HarmonyOS Native bridge 已连接 Rust ABI 2，可启动真实发送、接收与元数据解析。'
      return snapshot
    }
    snapshot.availability = EngineAvailability.UNAVAILABLE
    snapshot.message = '传输引擎未就绪：' + bridge.bridgeStatus + '，ABI ' + bridge.abiVersion + '，Rust 链接状态 ' +
      (bridge.rustLinked ? '已连接' : '未连接') + '。'
    return snapshot
  }

  subscribe(listener: EngineListener): void {
    this.listeners.push(listener)
    listener.onAvailabilityChanged(this.getAvailability())
  }

  unsubscribe(listener: EngineListener): void {
    this.listeners = this.listeners.filter((item: EngineListener) => item !== listener)
  }

  subscribeNode(listener: NodeListener): void {
    this.nodeListeners.push(listener)
    listener.onNodeChanged(this.nodeSnapshot.clone())
    listener.onDevicesChanged(this.copyPairedDevices(), this.copyNearbyDevices())
  }

  unsubscribeNode(listener: NodeListener): void {
    this.nodeListeners = this.nodeListeners.filter((item: NodeListener) => item !== listener)
  }

  getNodeSnapshot(): NodeSnapshot {
    return this.nodeSnapshot.clone()
  }

  async initializeNode(): Promise<void> {
    if (this.nodeStartInFlight || this.nodeSnapshot.status === 'starting' || this.nodeSnapshot.status === 'ready') {
      return
    }
    this.nodeStartInFlight = true
    try {
      let statusResponse: NativeNodeStatusResponse = JSON.parse(nativeBridge.nodeStatus()) as NativeNodeStatusResponse
      if (!statusResponse.ok) {
        throw new Error(statusResponse.error === undefined ? '无法读取设备节点状态。' :
          this.nativeErrorMessage(statusResponse.error))
      }
      let nativeStatus: NativeNodeStatusData | undefined = statusResponse.data
      if (nativeStatus !== undefined && nativeStatus.status !== 'stopped') {
        this.adoptNativeNodeStatus(nativeStatus)
        if (nativeStatus.status === 'ready') {
          await this.refreshDevices()
        }
        return
      }

      let settings: AppSettings = await platformService.loadSettings()
      let sessionId: string = this.createSessionId('node')
      this.nodeSessionId = sessionId
      this.nodeSnapshot.status = 'starting'
      this.nodeSnapshot.message = '正在启动 Iroh 设备节点。'
      this.notifyNodeChanged()
      let network: NativeNetworkConfig = this.networkConfig(settings)
      let request: NativeNodeStartRequest = {
        sessionId: sessionId,
        dataDir: platformService.prepareNodeDataDirectory(),
        displayName: settings.deviceName,
        deviceType: platformService.getNodeDeviceType(),
        discoverability: settings.discoverable ? 'everyone' : 'off',
        relayMode: network.relayMode,
        relayUrls: network.relayUrls,
        discoveryMode: network.discoveryMode
      }
      let response: NativeStartResponse = JSON.parse(
        nativeBridge.startNode(JSON.stringify(request), (eventJson: string): void => {
          this.processNodeEvent(eventJson, sessionId)
        })
      ) as NativeStartResponse
      let responseError: string = this.validateStartResponse(response, sessionId)
      if (responseError.length > 0) {
        this.nodeSessionId = ''
        this.nodeSnapshot.status = 'error'
        this.nodeSnapshot.message = responseError
        this.notifyNodeChanged()
      }
    } catch (error) {
      this.nodeSessionId = ''
      this.nodeSnapshot.status = 'error'
      this.nodeSnapshot.message = this.caughtMessage(error as Error)
      this.notifyNodeChanged()
    } finally {
      this.nodeStartInFlight = false
    }
  }

  async stopNode(): Promise<void> {
    if (this.nodeSessionId.length === 0) {
      return
    }
    try {
      let request: NativeCancelRequest = { sessionId: this.nodeSessionId }
      let response: NativeBasicResponse = JSON.parse(
        nativeBridge.stopNode(JSON.stringify(request))
      ) as NativeBasicResponse
      if (!response.ok) {
        this.nodeSnapshot.message = response.error === undefined ? '设备节点拒绝停止请求。' :
          this.nativeErrorMessage(response.error)
        this.notifyNodeChanged()
        return
      }
      this.nodeSnapshot.status = 'stopping'
      this.nodeSnapshot.message = '正在停止设备节点。'
      this.notifyNodeChanged()
    } catch (error) {
      this.nodeSnapshot.message = this.caughtMessage(error as Error)
      this.notifyNodeChanged()
    }
  }

  async listPairedDevices(): Promise<Array<PairedDevice>> {
    if (this.nodeSnapshot.status === 'ready') {
      await this.refreshDevices()
    }
    return this.copyPairedDevices()
  }

  async listNearbyDevices(): Promise<Array<NearbyDevice>> {
    if (this.nodeSnapshot.status === 'ready') {
      await this.refreshDevices()
    }
    return this.copyNearbyDevices()
  }

  async listHistory(): Promise<Array<HistoryEntry>> {
    return platformService.loadHistory()
  }

  async loadSettings(): Promise<AppSettings> {
    return platformService.loadSettings()
  }

  async send(items: Array<TransferItem>, onProgress: TransferProgressCallback): Promise<void> {
    let sessionId: string = this.createSessionId('share')
    let runtime: TransferRuntime = new TransferRuntime()
    runtime.progress = this.makeProgress(
      sessionId,
      items.length > 0 ? TransferStage.SHARING : TransferStage.IDLE,
      items.length > 0 ? '正在暂存发送内容' : '等待选择内容',
      items.length > 0 ? '正在把所选内容复制到应用沙箱。' : '请先选择要发送的文件或文件夹。'
    )
    onProgress(runtime.progress)
    if (items.length === 0) {
      return
    }

    let stagedPaths: Array<string> = []
    let stagedDirectory: string = ''
    try {
      stagedPaths = await platformService.stageShareItems(sessionId, items)
      stagedDirectory = this.parentPath(stagedPaths[0])
      this.transferDirectories.set(sessionId, stagedDirectory)
      let metadata: TransferMetadata = await platformService.buildTransferMetadata(stagedPaths)
      runtime.progress = this.makeProgress(
        sessionId,
        TransferStage.SHARING,
        '正在启动共享',
        metadata.itemCount + ' 项，' + this.formatBytes(metadata.size)
      )
      runtime.progress.bytesLabel = '0 B / ' + this.formatBytes(metadata.size)
      runtime.progress.itemCount = metadata.itemCount
      runtime.progress.totalBytes = metadata.size
      runtime.progress.speedLabel = '0 B/s'
      onProgress(runtime.progress)

      let network: NativeNetworkConfig = this.networkConfig(await platformService.loadSettings())
      let request: NativeShareRequest = {
        sessionId: sessionId,
        paths: stagedPaths,
        metadata: this.toNativeMetadata(metadata),
        ticketType: 'relayAndAddresses',
        relayMode: network.relayMode,
        relayUrls: network.relayUrls,
        discoveryMode: network.discoveryMode
      }
      let responseJson: string = nativeBridge.startShare(JSON.stringify(request), (eventJson: string): void => {
        this.processShareEvent(eventJson, sessionId, stagedDirectory, metadata, runtime, onProgress)
      })
      let response: NativeStartResponse = JSON.parse(responseJson) as NativeStartResponse
      let responseError: string = this.validateStartResponse(response, sessionId)
      if (responseError.length > 0 && !runtime.terminal) {
        runtime.terminal = true
        this.cleanupSession(sessionId, stagedDirectory)
        onProgress(this.makeErrorProgress(sessionId, '共享启动失败', responseError))
      } else if (!runtime.terminal) {
        systemIntegrationService.startTransfer(sessionId, 'send', runtime.progress)
      }
    } catch (error) {
      if (!runtime.terminal) {
        runtime.terminal = true
        this.cleanupSession(sessionId, stagedDirectory)
        onProgress(this.makeErrorProgress(sessionId, '共享启动失败', this.caughtMessage(error as Error)))
      }
    }
  }

  async receive(ticket: string, targetUri: string, onProgress: TransferProgressCallback): Promise<void> {
    let sessionId: string = this.createSessionId('receive')
    let runtime: TransferRuntime = new TransferRuntime()
    runtime.progress = this.makeProgress(
      sessionId,
      ticket.length > 0 && targetUri.length > 0 ? TransferStage.RECEIVING : TransferStage.IDLE,
      ticket.length > 0 ? '正在准备接收' : '等待票据',
      ticket.length === 0 ? '请输入票据并选择保存位置。' :
        (targetUri.length === 0 ? '请选择保存位置。' : '正在创建沙箱输出目录。')
    )
    runtime.progress.ticket = ticket
    onProgress(runtime.progress)
    if (ticket.length === 0 || targetUri.length === 0) {
      return
    }

    let outputDirectory: string = ''
    try {
      outputDirectory = platformService.prepareReceiveOutput(sessionId)
      this.transferDirectories.set(sessionId, outputDirectory)
      let network: NativeNetworkConfig = this.networkConfig(await platformService.loadSettings())
      let request: NativeReceiveRequest = {
        sessionId: sessionId,
        ticket: ticket,
        outputDir: outputDirectory,
        relayMode: network.relayMode,
        relayUrls: network.relayUrls,
        discoveryMode: network.discoveryMode
      }
      let responseJson: string = nativeBridge.startReceive(JSON.stringify(request), (eventJson: string): void => {
        this.processReceiveEvent(eventJson, sessionId, outputDirectory, targetUri, runtime, onProgress)
      })
      let response: NativeStartResponse = JSON.parse(responseJson) as NativeStartResponse
      let responseError: string = this.validateStartResponse(response, sessionId)
      if (responseError.length > 0 && !runtime.terminal) {
        runtime.terminal = true
        this.cleanupSession(sessionId, outputDirectory)
        onProgress(this.makeErrorProgress(sessionId, '接收启动失败', responseError))
      } else if (!runtime.terminal) {
        systemIntegrationService.startTransfer(sessionId, 'receive', runtime.progress)
      }
    } catch (error) {
      if (!runtime.terminal) {
        runtime.terminal = true
        this.cleanupSession(sessionId, outputDirectory)
        onProgress(this.makeErrorProgress(sessionId, '接收启动失败', this.caughtMessage(error as Error)))
      }
    }
  }

  async fetchMetadata(ticket: string, onResult: MetadataCallback): Promise<void> {
    if (ticket.trim().length === 0) {
      onResult(null, '请输入票据后再解析元数据。')
      return
    }
    let sessionId: string = this.createSessionId('metadata')
    try {
      let network: NativeNetworkConfig = this.networkConfig(await platformService.loadSettings())
      let request: NativeMetadataRequest = {
        sessionId: sessionId,
        ticket: ticket.trim(),
        relayMode: network.relayMode,
        relayUrls: network.relayUrls,
        discoveryMode: network.discoveryMode
      }
      let responseJson: string = nativeBridge.fetchMetadata(JSON.stringify(request), (eventJson: string): void => {
        this.processMetadataEvent(eventJson, sessionId, onResult)
      })
      let response: NativeStartResponse = JSON.parse(responseJson) as NativeStartResponse
      let responseError: string = this.validateStartResponse(response, sessionId)
      if (responseError.length > 0) {
        onResult(null, responseError)
      }
    } catch (error) {
      onResult(null, this.caughtMessage(error as Error))
    }
  }

  async pair(deviceId: string): Promise<string> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'requestNearbyPair',
      endpointId: deviceId
    }
    let result: NativePairDeliveryResult = JSON.parse(
      await this.runNodeCommand(request)
    ) as NativePairDeliveryResult
    if (!result.delivered) {
      throw new Error('附近设备当前无法接收配对请求。')
    }
    return '配对请求已发送，等待对方确认。'
  }

  async startPairingHost(ttlSecs: number = 300): Promise<string> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'startPairingHost',
      ttlSecs: ttlSecs
    }
    let result: NativePairingHostResult = JSON.parse(
      await this.runNodeCommand(request)
    ) as NativePairingHostResult
    this.nodeSnapshot.pairingTicket = result.ticket
    this.nodeSnapshot.message = '配对票据已生成，等待另一台设备加入。'
    this.notifyNodeChanged()
    return result.ticket
  }

  async stopPairingHost(): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'stopPairingHost'
    }
    await this.runNodeCommand(request)
    this.nodeSnapshot.pairingTicket = ''
    this.notifyNodeChanged()
  }

  async joinPairing(ticket: string): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'joinPairing',
      ticket: ticket.trim()
    }
    await this.runNodeCommand(request)
    await this.refreshDevices()
  }

  async respondNearbyPair(requestData: NearbyPairRequest, accept: boolean, block: boolean = false): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'respondNearbyInvite',
      endpointId: requestData.endpointId,
      accept: accept,
      block: block
    }
    await this.runNodeCommand(request)
    await this.refreshDevices()
  }

  async respondTransferInvite(invite: IncomingTransferInvite, accept: boolean): Promise<void> {
    await this.refreshDevices()
    let paired: boolean = this.pairedDevices.some((device: PairedDevice) => device.id === invite.endpointId &&
      device.pairingStatus === 'active')
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: paired ? 'respondPairedInvite' : 'respondNearbyInvite',
      endpointId: invite.endpointId,
      accept: accept
    }
    if (!paired) {
      request.block = false
    }
    await this.runNodeCommand(request)
    if (accept) {
      await this.refreshDevices()
    }
  }

  async forgetPaired(deviceId: string): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'forgetPaired',
      endpointId: deviceId
    }
    await this.runNodeCommand(request)
    await this.refreshDevices()
  }

  async renameDevice(displayName: string): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'renameDevice',
      displayName: displayName
    }
    await this.runNodeCommand(request)
    this.nodeSnapshot.deviceName = displayName.trim()
    this.notifyNodeChanged()
  }

  async setDiscoverable(discoverable: boolean): Promise<void> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: 'setDiscoverability',
      discoverability: discoverable ? 'everyone' : 'off'
    }
    await this.runNodeCommand(request)
    if (!discoverable) {
      this.nearbyDevices = []
    }
    await this.refreshDevices()
  }

  async inviteDevice(
    deviceId: string,
    paired: boolean,
    blobTicket: string,
    fileCount: number,
    totalSize: number
  ): Promise<boolean> {
    let request: NativeNodeCommandRequest = {
      sessionId: this.createSessionId('node-command'),
      operation: paired ? 'invitePaired' : 'inviteNearby',
      endpointId: deviceId,
      blobTicket: blobTicket,
      fileCount: fileCount,
      totalSize: totalSize
    }
    let result: NativePairDeliveryResult = JSON.parse(
      await this.runNodeCommand(request)
    ) as NativePairDeliveryResult
    return result.delivered
  }

  async cancel(transferId: string): Promise<boolean> {
    if (transferId.length === 0) {
      return false
    }
    try {
      let request: NativeCancelRequest = { sessionId: transferId }
      let response: NativeBasicResponse = JSON.parse(
        nativeBridge.cancelOperation(JSON.stringify(request))
      ) as NativeBasicResponse
      if (!response.ok) {
        return false
      }
      return true
    } catch (_error) {
      return false
    }
  }

  private adoptNativeNodeStatus(status: NativeNodeStatusData): void {
    this.nodeSnapshot.status = status.status
    if (status.sessionId !== undefined) {
      this.nodeSessionId = status.sessionId
    }
    if (status.deviceInfo !== undefined) {
      this.applyDeviceInfo(status.deviceInfo)
    }
    this.nodeSnapshot.networkReady = status.networkReady ?? false
    if (status.status === 'ready') {
      this.nodeSnapshot.message = this.nodeReadyMessage(this.nodeSnapshot.networkReady, status.nearbyUnavailableReason)
    } else if (status.status === 'starting') {
      this.nodeSnapshot.message = status.stopRequested ? '设备节点启动后将立即停止。' : '正在启动设备节点。'
    } else if (status.status === 'stopping') {
      this.nodeSnapshot.message = '正在停止设备节点。'
    }
    this.notifyNodeChanged()
  }

  private applyDeviceInfo(info: NativeNodeDeviceInfo): void {
    this.nodeSnapshot.endpointId = info.endpoint_id
    this.nodeSnapshot.deviceName = info.display_name
    this.nodeSnapshot.deviceType = info.device_type
  }

  private nodeReadyMessage(networkReady: boolean, nearbyUnavailableReason?: string | null): string {
    if (nearbyUnavailableReason !== undefined && nearbyUnavailableReason !== null && nearbyUnavailableReason.length > 0) {
      return '附近设备发现不可用：' + nearbyUnavailableReason
    }
    return networkReady ? '设备节点已就绪，正在发现附近设备。' : '设备节点已启动，网络仍在预热。'
  }

  private runNodeCommand(request: NativeNodeCommandRequest): Promise<string> {
    if (this.nodeSnapshot.status !== 'ready') {
      return Promise.reject(new Error('设备节点尚未就绪。'))
    }
    return new Promise<string>((resolve, reject) => {
      try {
        let responseJson: string = nativeBridge.nodeCommand(
          JSON.stringify(request),
          (eventJson: string): void => {
            try {
              let header: NativeEventHeader = JSON.parse(eventJson) as NativeEventHeader
              if (header.sessionId !== request.sessionId) {
                reject(new Error('原生节点命令返回了不匹配的会话标识。'))
                return
              }
              if (header.eventName === 'node-command-completed') {
                let event: NativeNodeCommandEvent = JSON.parse(eventJson) as NativeNodeCommandEvent
                if (event.data.operation !== request.operation) {
                  reject(new Error('原生节点命令返回了不匹配的操作标识。'))
                  return
                }
                resolve(JSON.stringify(event.data.result))
                return
              }
              if (header.eventName === 'operation-failed') {
                let event: NativeErrorEvent = JSON.parse(eventJson) as NativeErrorEvent
                reject(new Error(this.nativeErrorMessage(event.data)))
                return
              }
              reject(new Error('原生节点命令返回了未知事件: ' + header.eventName))
            } catch (error) {
              reject(new Error(this.caughtMessage(error as Error)))
            }
          }
        )
        let response: NativeStartResponse = JSON.parse(responseJson) as NativeStartResponse
        let responseError: string = this.validateStartResponse(response, request.sessionId)
        if (responseError.length > 0) {
          reject(new Error(responseError))
        }
      } catch (error) {
        reject(new Error(this.caughtMessage(error as Error)))
      }
    })
  }

  private async refreshDevices(): Promise<void> {
    if (this.nodeSnapshot.status !== 'ready') {
      return
    }
    if (this.deviceRefreshInFlight) {
      this.deviceRefreshPending = true
      return
    }
    this.deviceRefreshInFlight = true
    try {
      let pairedRequest: NativeNodeCommandRequest = {
        sessionId: this.createSessionId('node-command'),
        operation: 'listPaired'
      }
      let pairedData: Array<NativePairedDeviceData> = JSON.parse(
        await this.runNodeCommand(pairedRequest)
      ) as Array<NativePairedDeviceData>
      this.pairedDevices = pairedData.map((data: NativePairedDeviceData): PairedDevice => {
        return this.mapPairedDevice(data)
      })

      let nearbyRequest: NativeNodeCommandRequest = {
        sessionId: this.createSessionId('node-command'),
        operation: 'listNearby'
      }
      let nearbyData: Array<NativeNearbyDeviceData> = JSON.parse(
        await this.runNodeCommand(nearbyRequest)
      ) as Array<NativeNearbyDeviceData>
      this.nearbyDevices = nearbyData.map((data: NativeNearbyDeviceData): NearbyDevice => {
        return this.mapNearbyDevice(data)
      })
      this.notifyDevicesChanged()
    } catch (error) {
      this.nodeSnapshot.message = '设备列表刷新失败：' + this.caughtMessage(error as Error)
      this.notifyNodeChanged()
    } finally {
      this.deviceRefreshInFlight = false
      if (this.deviceRefreshPending) {
        this.deviceRefreshPending = false
        await this.refreshDevices()
      }
    }
  }

  private async processNodeEvent(eventJson: string, sessionId: string): Promise<void> {
    try {
      let header: NativeEventHeader = JSON.parse(eventJson) as NativeEventHeader
      if (header.sessionId !== sessionId) {
        return
      }
      if (header.eventName === 'node-ready') {
        let event: NativeNodeReadyEvent = JSON.parse(eventJson) as NativeNodeReadyEvent
        this.nodeSnapshot.status = 'ready'
        this.nodeSnapshot.networkReady = event.data.networkReady
        this.applyDeviceInfo(event.data.deviceInfo)
        this.nodeSnapshot.message = this.nodeReadyMessage(event.data.networkReady, event.data.nearbyUnavailableReason)
        this.notifyNodeChanged()
        await this.refreshDevices()
        return
      }
      if (header.eventName === 'device-node-network-warming') {
        this.nodeSnapshot.networkReady = false
        this.nodeSnapshot.message = '设备节点正在重建网络连接。'
        this.notifyNodeChanged()
        return
      }
      if (header.eventName === 'device-node-network-ready') {
        this.nodeSnapshot.networkReady = true
        this.nodeSnapshot.message = '设备节点网络已就绪。'
        this.notifyNodeChanged()
        await this.refreshDevices()
        return
      }
      if (header.eventName === 'nearby-device-found' || header.eventName === 'nearby-device-lost' ||
        header.eventName === 'nearby-device-identified' || header.eventName === 'device-paired' ||
        header.eventName === 'device-unpaired' || header.eventName === 'paired-device-presence') {
        await this.refreshDevices()
        return
      }
      if (header.eventName === 'nearby-pair-request-received') {
        let event: NativeNearbyPairRequestEvent = JSON.parse(eventJson) as NativeNearbyPairRequestEvent
        let request: NearbyPairRequest = new NearbyPairRequest()
        request.endpointId = event.data.remote_endpoint_id
        request.senderName = event.data.sender_name
        request.deviceType = event.data.device_type
        request.os = event.data.os
        systemIntegrationService.notifyNearbyPairRequest(request)
        this.nodeListeners.forEach((listener: NodeListener) => {
          listener.onNearbyPairRequest(request)
        })
        return
      }
      if (header.eventName === 'paired-invite-received') {
        let event: NativeTransferInviteEvent = JSON.parse(eventJson) as NativeTransferInviteEvent
        let invite: IncomingTransferInvite = new IncomingTransferInvite()
        invite.endpointId = event.data.remote_endpoint_id
        invite.senderName = event.data.sender_name
        invite.ticket = event.data.blob_ticket
        invite.fileCount = event.data.file_count
        invite.totalSize = event.data.total_size
        invite.paired = this.pairedDevices.some((device: PairedDevice) => device.id === invite.endpointId &&
          device.pairingStatus === 'active')
        systemIntegrationService.notifyTransferInvite(invite)
        this.nodeListeners.forEach((listener: NodeListener) => {
          listener.onTransferInvite(invite)
        })
        return
      }
      if (header.eventName === 'nearby-unavailable') {
        let event: NativeNearbyUnavailableEvent = JSON.parse(eventJson) as NativeNearbyUnavailableEvent
        this.nodeSnapshot.message = '附近设备发现不可用：' + event.data.reason
        this.notifyNodeChanged()
        return
      }
      if (header.eventName === 'pairing-host-expired') {
        this.nodeSnapshot.pairingTicket = ''
        this.nodeSnapshot.message = '配对票据已过期。'
        this.notifyNodeChanged()
        return
      }
      if (header.eventName === 'node-stopped') {
        this.nodeSessionId = ''
        this.nodeSnapshot = new NodeSnapshot()
        this.pairedDevices = []
        this.nearbyDevices = []
        this.notifyNodeChanged()
        this.notifyDevicesChanged()
        return
      }
      if (header.eventName === 'operation-failed') {
        let event: NativeErrorEvent = JSON.parse(eventJson) as NativeErrorEvent
        this.nodeSessionId = ''
        this.nodeSnapshot.status = 'error'
        this.nodeSnapshot.networkReady = false
        this.nodeSnapshot.message = this.nativeErrorMessage(event.data)
        this.notifyNodeChanged()
        return
      }
      if (header.eventName === 'paired-invite-response') {
        this.nodeSnapshot.message = '远端设备已响应发送邀请。'
        this.notifyNodeChanged()
        await this.refreshDevices()
        return
      }
      if (header.eventName === 'identity-rotated') {
        this.nodeSnapshot.message = '本机设备身份已更新，需要重新配对旧设备。'
        this.notifyNodeChanged()
      }
    } catch (error) {
      this.nodeSnapshot.message = '无法处理设备节点事件：' + this.caughtMessage(error as Error)
      this.notifyNodeChanged()
    }
  }

  private mapPairedDevice(data: NativePairedDeviceData): PairedDevice {
    let item: PairedDevice = new PairedDevice()
    item.id = data.endpoint_id
    item.name = data.display_name
    item.deviceType = data.device_type
    item.os = data.os
    item.pairingStatus = data.pairing_status
    item.online = data.online
    if (data.pairing_status === 'active') {
      item.status = data.online ? '在线' : '离线'
    } else if (data.pairing_status === 'unpaired-remotely') {
      item.status = '远端已取消配对'
    } else {
      item.status = '本机身份已更新'
    }
    item.lastSeen = this.formatTimestamp(data.last_seen_at)
    return item
  }

  private mapNearbyDevice(data: NativeNearbyDeviceData): NearbyDevice {
    let item: NearbyDevice = new NearbyDevice()
    item.id = data.endpointId
    item.fingerprint = data.fingerprint
    item.name = data.displayName ?? data.fingerprint
    item.deviceType = data.deviceType ?? '未知设备'
    item.os = data.os ?? ''
    item.identified = data.identified
    item.signalLabel = 'Iroh 局域网发现'
    item.status = data.identified ? '身份已确认' : '等待身份响应'
    return item
  }

  private formatTimestamp(timestamp: number): string {
    if (!Number.isFinite(timestamp) || timestamp <= 0) {
      return '尚未上线'
    }
    return new Date(timestamp).toISOString()
  }

  private copyPairedDevices(): Array<PairedDevice> {
    return this.pairedDevices.map((source: PairedDevice): PairedDevice => {
      let item: PairedDevice = new PairedDevice()
      item.id = source.id
      item.name = source.name
      item.deviceType = source.deviceType
      item.os = source.os
      item.pairingStatus = source.pairingStatus
      item.online = source.online
      item.status = source.status
      item.lastSeen = source.lastSeen
      return item
    })
  }

  private copyNearbyDevices(): Array<NearbyDevice> {
    return this.nearbyDevices.map((source: NearbyDevice): NearbyDevice => {
      let item: NearbyDevice = new NearbyDevice()
      item.id = source.id
      item.name = source.name
      item.deviceType = source.deviceType
      item.os = source.os
      item.fingerprint = source.fingerprint
      item.identified = source.identified
      item.signalLabel = source.signalLabel
      item.status = source.status
      return item
    })
  }

  private notifyNodeChanged(): void {
    let snapshot: NodeSnapshot = this.nodeSnapshot.clone()
    this.nodeListeners.forEach((listener: NodeListener) => {
      listener.onNodeChanged(snapshot)
    })
  }

  private notifyDevicesChanged(): void {
    let paired: Array<PairedDevice> = this.copyPairedDevices()
    let nearby: Array<NearbyDevice> = this.copyNearbyDevices()
    this.nodeListeners.forEach((listener: NodeListener) => {
      listener.onDevicesChanged(paired, nearby)
    })
  }

  private async processShareEvent(
    eventJson: string,
    sessionId: string,
    stagedDirectory: string,
    metadata: TransferMetadata,
    runtime: TransferRuntime,
    onProgress: TransferProgressCallback
  ): Promise<void> {
    if (runtime.terminal) {
      return
    }
    try {
      let header: NativeEventHeader = JSON.parse(eventJson) as NativeEventHeader
      if (header.sessionId !== sessionId) {
        return
      }
      if (header.eventName === 'share-ready') {
        let event: NativeShareReadyEvent = JSON.parse(eventJson) as NativeShareReadyEvent
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.SHARING
        progress.title = '共享已就绪'
        progress.detail = '票据已生成，等待接收方连接。类型：' + event.data.entryType
        progress.ticket = event.data.ticket
        progress.bytesLabel = '0 B / ' + this.formatBytes(event.data.size)
        progress.speedLabel = '0 B/s'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'share-peer-connected') {
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.SHARING
        progress.title = '接收方已连接'
        progress.detail = '正在发送真实内容。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'transfer-progress') {
        let event: NativeProgressEvent = JSON.parse(eventJson) as NativeProgressEvent
        let progress: TransferProgress = this.progressFromPayload(runtime.progress, event.data, TransferStage.SHARING)
        progress.title = '正在发送'
        progress.detail = '接收方已连接，传输进行中。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'transfer-completed') {
        runtime.terminal = true
        systemIntegrationService.stopTransfer(sessionId)
        let event: NativeTransferCompletedEvent = JSON.parse(eventJson) as NativeTransferCompletedEvent
        let sessionClosed: boolean = await this.cancel(sessionId)
        let historyError: string = ''
        try {
          await this.appendHistory(
            sessionId,
            '发送',
            metadata.fileName,
            metadata.itemCount + ' 项 · ' + this.formatBytes(metadata.size),
            'completed'
          )
        } catch (error) {
          historyError = '发送完成，但历史记录保存失败：' + this.caughtMessage(error as Error)
        }
        this.cleanupSession(sessionId, stagedDirectory)
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.COMPLETED
        progress.title = '发送完成'
        progress.detail = event.data.message ?? '内容已由接收方完整接收。'
        progress.progressRatio = 1
        progress.bytesLabel = this.formatBytes(metadata.size) + ' / ' + this.formatBytes(metadata.size)
        progress.speedLabel = ''
        progress.errorMessage = historyError
        if (!sessionClosed) {
          progress.errorMessage = (progress.errorMessage.length > 0 ? progress.errorMessage + '\n' : '') +
            '内容已发送，但原生共享会话未能自动关闭。'
        }
        runtime.progress = progress
        onProgress(progress)
        return
      }
      if (header.eventName === 'operation-failed') {
        runtime.terminal = true
        systemIntegrationService.stopTransfer(sessionId)
        let event: NativeErrorEvent = JSON.parse(eventJson) as NativeErrorEvent
        this.cleanupSession(sessionId, stagedDirectory)
        onProgress(this.makeErrorProgress(sessionId, '发送失败', this.nativeErrorMessage(event.data)))
        return
      }
      if (header.eventName === 'operation-cancelled') {
        runtime.terminal = true
        systemIntegrationService.stopTransfer(sessionId)
        this.cleanupSession(sessionId, stagedDirectory)
        onProgress(this.makeCancelledProgress(sessionId, '发送已取消'))
      }
    } catch (error) {
      let progress: TransferProgress = this.copyProgress(runtime.progress)
      progress.errorMessage = '无法处理发送事件：' + this.caughtMessage(error as Error)
      runtime.progress = progress
      onProgress(progress)
    }
  }

  private async processReceiveEvent(
    eventJson: string,
    sessionId: string,
    outputDirectory: string,
    targetUri: string,
    runtime: TransferRuntime,
    onProgress: TransferProgressCallback
  ): Promise<void> {
    if (runtime.terminal) {
      return
    }
    try {
      let header: NativeEventHeader = JSON.parse(eventJson) as NativeEventHeader
      if (header.sessionId !== sessionId) {
        return
      }
      if (header.eventName === 'receive-started') {
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.RECEIVING
        progress.title = '接收已开始'
        progress.detail = '已连接发送方，正在准备文件。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'receive-file-names') {
        let event: NativeStringArrayEvent = JSON.parse(eventJson) as NativeStringArrayEvent
        runtime.fileNames = [...event.data]
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.RECEIVING
        progress.title = '已读取文件清单'
        progress.detail = event.data.length > 0 ? event.data.join('、') : '发送方未提供文件名。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'receive-conflicts') {
        let event: NativeConflictEvent = JSON.parse(eventJson) as NativeConflictEvent
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.RECEIVING
        progress.title = '发现文件名冲突'
        progress.detail = event.data.length > 0 ? event.data.map((item: NativeConflictData) => {
          return item.original + ' → ' + item.resolved
        }).join('\n') : '引擎报告了文件名冲突。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'receive-progress') {
        let event: NativeProgressEvent = JSON.parse(eventJson) as NativeProgressEvent
        let progress: TransferProgress = this.progressFromPayload(runtime.progress, event.data, TransferStage.RECEIVING)
        progress.title = '正在接收'
        progress.detail = runtime.fileNames.length > 0 ? runtime.fileNames.join('、') : '正在写入应用沙箱。'
        runtime.progress = progress
        onProgress(progress)
        systemIntegrationService.updateTransfer(progress)
        return
      }
      if (header.eventName === 'receive-completed') {
        runtime.terminal = true
        let event: NativeTransferCompletedEvent = JSON.parse(eventJson) as NativeTransferCompletedEvent
        let exportedCount: number
        try {
          exportedCount = await platformService.exportReceivedFiles(outputDirectory, targetUri)
        } catch (error) {
          this.transferDirectories.delete(sessionId)
          systemIntegrationService.stopTransfer(sessionId)
          let progress: TransferProgress = this.makeErrorProgress(
            sessionId,
            '接收内容导出失败',
            this.caughtMessage(error as Error)
          )
          progress.detail = progress.detail + ' 沙箱输出保留在 ' + outputDirectory + '，目标位置可能包含已复制的部分文件。'
          runtime.progress = progress
          onProgress(progress)
          return
        }

        let historyError: string = ''
        let title: string = this.receiveTitle(runtime.fileNames, event.data.filePath ?? '')
        try {
          await this.appendHistory(
            sessionId,
            '接收',
            title,
            exportedCount + ' 个文件已导出到用户选择的位置',
            'completed'
          )
        } catch (error) {
          historyError = '接收与导出已完成，但历史记录保存失败：' + this.caughtMessage(error as Error)
        }
        this.cleanupSession(sessionId, outputDirectory)
        let progress: TransferProgress = this.copyProgress(runtime.progress)
        progress.stage = TransferStage.COMPLETED
        progress.title = '接收完成'
        progress.detail = (event.data.message ?? '文件接收完成。') + ' 已导出 ' + exportedCount + ' 个文件。'
        progress.progressRatio = 1
        progress.speedLabel = ''
        progress.errorMessage = historyError
        runtime.progress = progress
        systemIntegrationService.stopTransfer(sessionId)
        onProgress(progress)
        return
      }
      if (header.eventName === 'operation-failed') {
        runtime.terminal = true
        systemIntegrationService.stopTransfer(sessionId)
        let event: NativeErrorEvent = JSON.parse(eventJson) as NativeErrorEvent
        this.cleanupSession(sessionId, outputDirectory)
        onProgress(this.makeErrorProgress(sessionId, '接收失败', this.nativeErrorMessage(event.data)))
        return
      }
      if (header.eventName === 'operation-cancelled') {
        runtime.terminal = true
        systemIntegrationService.stopTransfer(sessionId)
        this.cleanupSession(sessionId, outputDirectory)
        onProgress(this.makeCancelledProgress(sessionId, '接收已取消'))
      }
    } catch (error) {
      let progress: TransferProgress = this.copyProgress(runtime.progress)
      progress.errorMessage = '无法处理接收事件：' + this.caughtMessage(error as Error)
      runtime.progress = progress
      onProgress(progress)
    }
  }

  private processMetadataEvent(eventJson: string, sessionId: string, onResult: MetadataCallback): void {
    try {
      let header: NativeEventHeader = JSON.parse(eventJson) as NativeEventHeader
      if (header.sessionId !== sessionId) {
        return
      }
      if (header.eventName === 'metadata-ready') {
        let event: NativeMetadataReadyEvent = JSON.parse(eventJson) as NativeMetadataReadyEvent
        onResult(this.fromNativeMetadata(event.data), '')
        return
      }
      if (header.eventName === 'operation-failed') {
        let event: NativeErrorEvent = JSON.parse(eventJson) as NativeErrorEvent
        onResult(null, this.nativeErrorMessage(event.data))
        return
      }
      if (header.eventName === 'operation-cancelled') {
        onResult(null, '元数据解析已取消。')
      }
    } catch (error) {
      onResult(null, this.caughtMessage(error as Error))
    }
  }

  private toNativeMetadata(metadata: TransferMetadata): NativeShareMetadata {
    let items: Array<NativeShareMetadataItem> = metadata.items.map((item: FilePreviewMetadata) => {
      let nativeItem: NativeShareMetadataItem = {
        file_name: item.fileName,
        size: item.size
      }
      return nativeItem
    })
    let nativeMetadata: NativeShareMetadata = {
      file_name: metadata.fileName,
      item_count: metadata.itemCount,
      size: metadata.size,
      items: items
    }
    return nativeMetadata
  }

  private fromNativeMetadata(data: NativeMetadataData): TransferMetadata {
    let metadata: TransferMetadata = new TransferMetadata()
    metadata.fileName = data.file_name
    metadata.itemCount = data.item_count
    metadata.size = data.size
    let items: Array<NativeMetadataItemData> = data.items ?? []
    items.forEach((entry: NativeMetadataItemData) => {
      let item: FilePreviewMetadata = new FilePreviewMetadata()
      item.fileName = entry.file_name
      item.size = entry.size
      metadata.items.push(item)
    })
    return metadata
  }

  private progressFromPayload(
    current: TransferProgress,
    payload: string,
    stage: TransferStage
  ): TransferProgress {
    let progress: TransferProgress = this.copyProgress(current)
    let parts: Array<string> = payload.split(':')
    let bytes: number = parts.length > 0 ? Number(parts[0]) : 0
    let total: number = parts.length > 1 ? Number(parts[1]) : 0
    let speedMilliBps: number = parts.length > 2 ? Number(parts[2]) : 0
    bytes = Number.isFinite(bytes) && bytes > 0 ? bytes : 0
    total = Number.isFinite(total) && total > 0 ? total : 0
    speedMilliBps = Number.isFinite(speedMilliBps) && speedMilliBps > 0 ? speedMilliBps : 0
    progress.stage = stage
    progress.progressRatio = total > 0 ? Math.min(bytes / total, 1) : 0
    progress.bytesLabel = this.formatBytes(bytes) + ' / ' + this.formatBytes(total)
    progress.speedLabel = this.formatBytes(speedMilliBps / 1000) + '/s'
    return progress
  }

  private makeProgress(
    transferId: string,
    stage: TransferStage,
    title: string,
    detail: string
  ): TransferProgress {
    let progress: TransferProgress = new TransferProgress()
    progress.transferId = transferId
    progress.stage = stage
    progress.title = title
    progress.detail = detail
    return progress
  }

  private makeErrorProgress(transferId: string, title: string, message: string): TransferProgress {
    let progress: TransferProgress = this.makeProgress(transferId, TransferStage.ERROR, title, message)
    progress.errorMessage = message
    return progress
  }

  private makeCancelledProgress(transferId: string, title: string): TransferProgress {
    return this.makeProgress(transferId, TransferStage.CANCELLED, title, '原生引擎已取消本次操作。')
  }

  private copyProgress(source: TransferProgress): TransferProgress {
    let progress: TransferProgress = new TransferProgress()
    progress.transferId = source.transferId
    progress.stage = source.stage
    progress.title = source.title
    progress.detail = source.detail
    progress.ticket = source.ticket
    progress.progressRatio = source.progressRatio
    progress.itemCount = source.itemCount
    progress.totalBytes = source.totalBytes
    progress.bytesLabel = source.bytesLabel
    progress.speedLabel = source.speedLabel
    progress.errorMessage = source.errorMessage
    return progress
  }

  private createSessionId(operation: string): string {
    this.sessionSequence += 1
    return operation + '-' + Date.now() + '-' + this.sessionSequence
  }

  private validateStartResponse(response: NativeStartResponse, sessionId: string): string {
    if (!response.ok) {
      return response.error === undefined ? '原生引擎拒绝启动操作。' : this.nativeErrorMessage(response.error)
    }
    if (response.data === undefined || !response.data.accepted) {
      return '原生引擎未接受启动请求。'
    }
    if (response.data.sessionId !== sessionId) {
      return '原生引擎返回了不匹配的会话标识。'
    }
    return ''
  }

  private nativeErrorMessage(error: NativeErrorData): string {
    return error.code.length > 0 ? error.code + ': ' + error.message : error.message
  }

  private caughtMessage(error: Error): string {
    return error.message.length > 0 ? error.message : '发生未知错误。'
  }

  private parentPath(path: string): string {
    let separatorIndex: number = path.lastIndexOf('/')
    return separatorIndex > 0 ? path.substring(0, separatorIndex) : path
  }

  private cleanupSession(sessionId: string, directory: string): void {
    if (directory.length > 0) {
      platformService.cleanupTransferDirectory(directory)
    }
    this.transferDirectories.delete(sessionId)
  }

  private receiveTitle(fileNames: Array<string>, filePath: string): string {
    if (fileNames.length === 1) {
      return fileNames[0]
    }
    if (fileNames.length > 1) {
      return fileNames[0] + ' 等 ' + fileNames.length + ' 个文件'
    }
    if (filePath.length > 0) {
      let separatorIndex: number = filePath.lastIndexOf('/')
      return separatorIndex >= 0 ? filePath.substring(separatorIndex + 1) : filePath
    }
    return '接收内容'
  }

  private async appendHistory(
    id: string,
    direction: string,
    title: string,
    detail: string,
    status: string
  ): Promise<void> {
    let entry: HistoryEntry = new HistoryEntry()
    entry.id = id
    entry.direction = direction
    entry.title = title
    entry.detail = detail
    entry.timestamp = new Date().toISOString()
    entry.status = status
    let current: Array<HistoryEntry> = await platformService.loadHistory()
    await platformService.saveHistory([entry, ...current].slice(0, HISTORY_LIMIT))
  }

  private formatBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '0 B'
    }
    let units: Array<string> = ['B', 'KB', 'MB', 'GB', 'TB']
    let value: number = bytes
    let unitIndex: number = 0
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024
      unitIndex += 1
    }
    let digits: number = unitIndex === 0 || value >= 100 ? 0 : (value >= 10 ? 1 : 2)
    return value.toFixed(digits) + ' ' + units[unitIndex]
  }
}

export const engineService: EngineService = new EngineService()