import {
  AppSettings,
  DisplayState,
  EngineAvailability,
  EngineSnapshot,
  HistoryEntry,
  IncomingTransferInvite,
  NavSection,
  NearbyDevice,
  NearbyPairRequest,
  NodeSnapshot,
  PairedDevice,
  TransferItem,
  TransferMetadata,
  TransferProgress,
  TransferStage
} from '../models/AppModels'
import { appLinkService, AppLinkListener } from '../services/AppLinkService'
import { engineService, NodeListener } from '../services/EngineService'
import { platformService } from '../services/PlatformService'

type NodeChangedCallback = (snapshot: NodeSnapshot) => void
type DevicesChangedCallback = (paired: Array<PairedDevice>, nearby: Array<NearbyDevice>) => void
type NearbyPairRequestCallback = (request: NearbyPairRequest) => void
type TransferInviteCallback = (invite: IncomingTransferInvite) => void

class AppShellNodeListener implements NodeListener {
  private readonly nodeChangedCallback: NodeChangedCallback
  private readonly devicesChangedCallback: DevicesChangedCallback
  private readonly nearbyPairRequestCallback: NearbyPairRequestCallback
  private readonly transferInviteCallback: TransferInviteCallback

  constructor(
    nodeChangedCallback: NodeChangedCallback,
    devicesChangedCallback: DevicesChangedCallback,
    nearbyPairRequestCallback: NearbyPairRequestCallback,
    transferInviteCallback: TransferInviteCallback
  ) {
    this.nodeChangedCallback = nodeChangedCallback
    this.devicesChangedCallback = devicesChangedCallback
    this.nearbyPairRequestCallback = nearbyPairRequestCallback
    this.transferInviteCallback = transferInviteCallback
  }

  onNodeChanged(snapshot: NodeSnapshot): void {
    this.nodeChangedCallback(snapshot)
  }

  onDevicesChanged(paired: Array<PairedDevice>, nearby: Array<NearbyDevice>): void {
    this.devicesChangedCallback(paired, nearby)
  }

  onNearbyPairRequest(request: NearbyPairRequest): void {
    this.nearbyPairRequestCallback(request)
  }

  onTransferInvite(invite: IncomingTransferInvite): void {
    this.transferInviteCallback(invite)
  }
}

@Component
export struct AppShell {
  @State private activeSection: NavSection = NavSection.SEND
  @State private breakpoint: string = 'sm'
  @State private viewportHeight: number = 720
  @State private sendItems: Array<TransferItem> = []
  @State private pairedDevices: Array<PairedDevice> = []
  @State private nearbyDevices: Array<NearbyDevice> = []
  @State private historyEntries: Array<HistoryEntry> = []
  @State private settings: AppSettings = new AppSettings()
  @State private displayState: DisplayState = new DisplayState()
  @State private engineSnapshot: EngineSnapshot = new EngineSnapshot()
  @State private nodeSnapshot: NodeSnapshot = new NodeSnapshot()
  @State private sendState: TransferProgress = new TransferProgress()
  @State private receiveState: TransferProgress = new TransferProgress()
  @State private receiveTicket: string = ''
  @State private receiveFolder: string = ''
  @State private receivePreviewTitle: string = '尚未解析票据'
  @State private receivePreviewDetail: string = '输入票据后可向发送方读取真实文件元数据。'
  @State private nodeOperationStatus: string = '等待 Iroh NodeService 就绪。'
  @State private pairingJoinTicket: string = ''
  @State private pendingNearbyPairRequest: NearbyPairRequest = new NearbyPairRequest()
  @State private hasPendingNearbyPairRequest: boolean = false
  @State private pendingTransferInvite: IncomingTransferInvite = new IncomingTransferInvite()
  @State private hasPendingTransferInvite: boolean = false
  @State private receiveInviteStatus: string = ''
  @State private sendInviteStatus: string = ''
  @State private folderSelectionSupported: boolean = platformService.isFolderSelectionSupported()

  private readonly nodeListener: NodeListener = new AppShellNodeListener(
    (snapshot: NodeSnapshot): void => {
      this.nodeSnapshot = snapshot
    },
    (paired: Array<PairedDevice>, nearby: Array<NearbyDevice>): void => {
      this.pairedDevices = paired
      this.nearbyDevices = nearby
    },
    (request: NearbyPairRequest): void => {
      this.pendingNearbyPairRequest = request
      this.hasPendingNearbyPairRequest = true
      this.nodeOperationStatus = '收到来自 ' + request.senderName + ' 的附近配对请求。'
    },
    (invite: IncomingTransferInvite): void => {
      this.pendingTransferInvite = invite
      this.hasPendingTransferInvite = true
      this.receiveInviteStatus = '收到来自 ' + invite.senderName + ' 的传输邀请，等待确认。'
    }
  )

  private readonly displayListener = (state: DisplayState): void => {
    this.displayState = state
  }

  private readonly appLinkListener: AppLinkListener = (ticket: string): void => {
    this.receiveTicket = ticket
    this.activeSection = NavSection.RECEIVE
    this.parseReceiveMetadata().catch((error: Error): void => {
      this.receivePreviewTitle = '元数据解析失败'
      this.receivePreviewDetail = error.message
    })
  }

  aboutToAppear(): void {
    this.engineSnapshot = engineService.getAvailability()
    this.nodeSnapshot = engineService.getNodeSnapshot()
    this.resetSendState()
    this.resetReceiveState()
    engineService.subscribeNode(this.nodeListener)
    platformService.subscribeDisplay(this.displayListener)
    appLinkService.subscribe(this.appLinkListener)
    this.loadInitialState().catch((error: Error): void => {
      this.nodeOperationStatus = '初始状态加载失败：' + error.message
    })
  }

  aboutToDisappear(): void {
    engineService.unsubscribeNode(this.nodeListener)
    platformService.unsubscribeDisplay(this.displayListener)
    appLinkService.unsubscribe(this.appLinkListener)
  }

  private async loadInitialState(): Promise<void> {
    try {
      this.folderSelectionSupported = platformService.isFolderSelectionSupported()
      await engineService.initializeNode()
      this.nodeSnapshot = engineService.getNodeSnapshot()
      this.pairedDevices = await engineService.listPairedDevices()
      this.nearbyDevices = await engineService.listNearbyDevices()
      this.historyEntries = await engineService.listHistory()
      this.settings = await engineService.loadSettings()
      this.displayState = platformService.getDisplayState()
    } catch (error) {
      throw new Error((error as Error).message)
    }
  }

  private resetSendState(): void {
    let progress: TransferProgress = new TransferProgress()
    progress.stage = TransferStage.IDLE
    progress.title = '等待选择内容'
    progress.detail = '选择文件或文件夹后即可通过原生引擎生成共享票据。'
    this.sendState = progress
  }

  private resetReceiveState(): void {
    let progress: TransferProgress = new TransferProgress()
    progress.stage = TransferStage.IDLE
    progress.title = '等待票据'
    progress.detail = '输入票据并选择保存位置后即可开始接收。'
    this.receiveState = progress
  }

  private markSelectedState(): void {
    if (this.sendItems.length === 0) {
      this.resetSendState()
      return
    }
    let progress: TransferProgress = new TransferProgress()
    progress.stage = TransferStage.SELECTED
    progress.title = '已选择内容'
    progress.detail = '已准备 ' + this.sendItems.length + ' 项，等待开始共享。'
    this.sendState = progress
  }

  private async chooseFiles(): Promise<void> {
    let items: Array<TransferItem> = await platformService.selectFiles()
    this.sendItems = [...this.sendItems, ...items]
    this.markSelectedState()
  }

  private async chooseFolder(): Promise<void> {
    try {
      let items: Array<TransferItem> = await platformService.selectFolder()
      this.sendItems = [...this.sendItems, ...items]
      this.markSelectedState()
    } catch (error) {
      let progress: TransferProgress = new TransferProgress()
      progress.stage = TransferStage.ERROR
      progress.title = '选择文件夹不可用'
      progress.detail = (error as Error).message
      progress.errorMessage = '当前设备未提供文件夹选择能力。'
      this.sendState = progress
    }
  }

  private clearSendItems(): void {
    this.sendItems = []
    this.resetSendState()
  }

  private async chooseReceiveTarget(): Promise<void> {
    let targetUri: string = await platformService.chooseSaveTarget('dashbeam-receive.bin')
    if (targetUri.length === 0) {
      return
    }
    this.receiveFolder = targetUri
  }

  private async copyCurrentTicket(): Promise<void> {
    if (this.sendState.ticket.length === 0) {
      return
    }
    let copied: boolean = await platformService.copyTicket(this.sendState.ticket)
    if (!copied) {
      return
    }
    let progress: TransferProgress = new TransferProgress()
    progress.stage = this.sendState.stage
    progress.transferId = this.sendState.transferId
    progress.title = this.sendState.title
    progress.detail = this.sendState.detail + '\n票据已复制到系统剪贴板。'
    progress.ticket = this.sendState.ticket
    progress.progressRatio = this.sendState.progressRatio
    progress.itemCount = this.sendState.itemCount
    progress.totalBytes = this.sendState.totalBytes
    progress.bytesLabel = this.sendState.bytesLabel
    progress.speedLabel = this.sendState.speedLabel
    progress.errorMessage = this.sendState.errorMessage
    this.sendState = progress
  }

  private async persistSettings(nextSettings: AppSettings): Promise<boolean> {
    this.settings = nextSettings.clone()
    try {
      this.settings = await platformService.saveSettings(nextSettings)
      return true
    } catch (error) {
      this.nodeOperationStatus = '设置保存失败：' + (error as Error).message
      return false
    }
  }

  private async updateDeviceName(value: string): Promise<void> {
    let normalizedValue: string = value.trim()
    if (normalizedValue.length === 0 || normalizedValue.length > 64) {
      this.nodeOperationStatus = '设备名必须为 1 至 64 个字符。'
      return
    }
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.deviceName = normalizedValue
    if (!await this.persistSettings(nextSettings)) {
      return
    }
    if (this.nodeSnapshot.status !== 'ready') {
      this.nodeOperationStatus = '设备名已保存；NodeService 就绪后将在下次启动时使用。'
      return
    }
    try {
      await engineService.renameDevice(normalizedValue)
      this.nodeOperationStatus = '设备名已保存并同步到 Iroh NodeService。'
    } catch (error) {
      this.nodeOperationStatus = '设备名已保存，但节点重命名失败：' + (error as Error).message
    }
  }

  private async updateTheme(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.theme = value
    await this.persistSettings(nextSettings)
  }

  private async updateRelay(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.defaultRelay = value
    await this.persistSettings(nextSettings)
  }

  private async updateDiscovery(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.defaultDiscovery = value
    await this.persistSettings(nextSettings)
  }

  private async updateDnsOrigin(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.dnsOrigin = value
    await this.persistSettings(nextSettings)
  }

  private async updateDiscoverable(value: boolean): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.discoverable = value
    if (!await this.persistSettings(nextSettings)) {
      return
    }
    if (this.nodeSnapshot.status !== 'ready') {
      this.nodeOperationStatus = '可发现性已保存；NodeService 就绪后将在下次启动时使用。'
      return
    }
    try {
      await engineService.setDiscoverable(value)
      this.nodeOperationStatus = value ? '附近设备发现已开启。' : '附近设备发现已关闭。'
    } catch (error) {
      this.nodeOperationStatus = '可发现性已保存，但节点更新失败：' + (error as Error).message
    }
  }

  private async updateResumeInBackground(value: boolean): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.resumeInBackground = value
    await this.persistSettings(nextSettings)
  }

  private updateBreakpoint(width: number, height: number): void {
    this.viewportHeight = height
    if (width >= 840) {
      this.breakpoint = 'lg'
      return
    }
    if (width >= 600) {
      this.breakpoint = 'md'
      return
    }
    this.breakpoint = 'sm'
  }

  private compactHeight(): boolean {
    return this.viewportHeight < 620
  }

  private navTitle(section: NavSection): string {
    if (section === NavSection.SEND) {
      return '发送'
    }
    if (section === NavSection.RECEIVE) {
      return '接收'
    }
    if (section === NavSection.DEVICES) {
      return '设备'
    }
    if (section === NavSection.HISTORY) {
      return '历史'
    }
    return '设置'
  }

  private sectionSubtitle(): string {
    if (this.activeSection === NavSection.SEND) {
      return '选择真实文件 URI，生成票据并查看实时发送进度。'
    }
    if (this.activeSection === NavSection.RECEIVE) {
      return '输入票据、预览元数据并选择真实保存目标。'
    }
    if (this.activeSection === NavSection.DEVICES) {
      return '查看 Iroh NodeService、已配对设备与附近设备。'
    }
    if (this.activeSection === NavSection.HISTORY) {
      return '历史记录来自 Preferences 持久化，初始为空。'
    }
    return '调整并持久化设备名、网络配置与恢复选项。'
  }

  private stageLabel(stage: TransferStage): string {
    if (stage === TransferStage.SELECTED) {
      return '已选择'
    }
    if (stage === TransferStage.SHARING) {
      return '分享中'
    }
    if (stage === TransferStage.RECEIVING) {
      return '接收中'
    }
    if (stage === TransferStage.COMPLETED) {
      return '完成'
    }
    if (stage === TransferStage.CANCELLED) {
      return '已取消'
    }
    if (stage === TransferStage.ERROR) {
      return '错误'
    }
    return '空闲'
  }

  private async startShare(): Promise<void> {
    let pending: TransferProgress = new TransferProgress()
    pending.stage = TransferStage.SHARING
    pending.title = '正在启动共享'
    pending.detail = '正在准备所选内容。'
    this.sendState = pending
    await engineService.send(this.sendItems, (progress: TransferProgress): void => {
      this.sendState = progress
      if (progress.stage === TransferStage.COMPLETED) {
        this.refreshHistory()
      }
    })
  }

  private async startReceive(): Promise<void> {
    let pending: TransferProgress = new TransferProgress()
    pending.stage = TransferStage.RECEIVING
    pending.title = '正在启动接收'
    pending.detail = '正在准备沙箱输出目录。'
    pending.ticket = this.receiveTicket
    this.receiveState = pending
    await engineService.receive(this.receiveTicket, this.receiveFolder, (progress: TransferProgress): void => {
      this.receiveState = progress
      if (progress.stage === TransferStage.COMPLETED) {
        this.refreshHistory()
      }
    })
  }

  private async parseReceiveMetadata(): Promise<void> {
    let requestedTicket: string = this.receiveTicket.trim()
    this.receivePreviewTitle = requestedTicket.length > 0 ? '正在解析票据' : '尚未解析票据'
    this.receivePreviewDetail = requestedTicket.length > 0 ? '正在向发送方读取文件元数据。' : '请输入票据后再解析。'
    await engineService.fetchMetadata(
      requestedTicket,
      (metadata: TransferMetadata | null, errorMessage: string): void => {
        if (this.receiveTicket.trim() !== requestedTicket) {
          return
        }
        if (metadata === null) {
          this.receivePreviewTitle = '元数据解析失败'
          this.receivePreviewDetail = errorMessage
          return
        }
        this.receivePreviewTitle = metadata.fileName
        this.receivePreviewDetail = metadata.itemCount + ' 项 · ' + this.formatBytes(metadata.size) +
          (metadata.items.length > 0 ? '\n' + metadata.items.map((item) => item.fileName + ' · ' +
            this.formatBytes(item.size)).join('\n') : '')
      }
    )
  }

  private async refreshHistory(): Promise<void> {
    this.historyEntries = await engineService.listHistory()
  }

  private async cancelTransfer(transferId: string): Promise<void> {
    let accepted: boolean = await engineService.cancel(transferId)
    if (accepted) {
      return
    }
    if (this.sendState.transferId === transferId && this.sendState.stage === TransferStage.SHARING) {
      let progress: TransferProgress = this.copyProgress(this.sendState)
      progress.errorMessage = '原生引擎未接受取消请求。'
      this.sendState = progress
    }
    if (this.receiveState.transferId === transferId && this.receiveState.stage === TransferStage.RECEIVING) {
      let progress: TransferProgress = this.copyProgress(this.receiveState)
      progress.errorMessage = '原生引擎未接受取消请求。'
      this.receiveState = progress
    }
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

  private async triggerPair(deviceId: string): Promise<void> {
    try {
      this.nodeOperationStatus = '正在发送附近配对请求。'
      this.nodeOperationStatus = await engineService.pair(deviceId)
    } catch (error) {
      this.nodeOperationStatus = '配对请求失败：' + (error as Error).message
    }
  }

  private async inviteTransfer(deviceId: string, paired: boolean): Promise<void> {
    if (this.sendState.ticket.length === 0) {
      this.sendInviteStatus = '请先开始共享并等待真实票据生成。'
      return
    }
    try {
      this.sendInviteStatus = '正在发送设备邀请。'
      let delivered: boolean = await engineService.inviteDevice(
        deviceId,
        paired,
        this.sendState.ticket,
        this.sendState.itemCount,
        this.sendState.totalBytes
      )
      this.sendInviteStatus = delivered ? '设备邀请已送达，等待对方确认。' : '设备当前无法接收邀请。'
    } catch (error) {
      this.sendInviteStatus = '设备邀请失败：' + (error as Error).message
    }
  }

  private async respondToNearbyPair(accept: boolean, block: boolean): Promise<void> {
    if (!this.hasPendingNearbyPairRequest) {
      return
    }
    let request: NearbyPairRequest = this.pendingNearbyPairRequest
    try {
      this.nodeOperationStatus = accept ? '正在接受附近配对请求。' : '正在拒绝附近配对请求。'
      await engineService.respondNearbyPair(request, accept, block)
      this.hasPendingNearbyPairRequest = false
      this.pendingNearbyPairRequest = new NearbyPairRequest()
      this.nodeOperationStatus = accept ? '已接受 ' + request.senderName + ' 的配对请求。' :
        (block ? '已拒绝并阻止 ' + request.senderName + '。' : '已拒绝 ' + request.senderName + ' 的配对请求。')
    } catch (error) {
      this.nodeOperationStatus = '处理配对请求失败：' + (error as Error).message
    }
  }

  private async respondToTransferInvite(accept: boolean): Promise<void> {
    if (!this.hasPendingTransferInvite) {
      return
    }
    let invite: IncomingTransferInvite = this.pendingTransferInvite
    try {
      this.receiveInviteStatus = accept ? '正在接受传输邀请。' : '正在拒绝传输邀请。'
      await engineService.respondTransferInvite(invite, accept)
      this.hasPendingTransferInvite = false
      this.pendingTransferInvite = new IncomingTransferInvite()
      if (!accept) {
        this.receiveInviteStatus = '已拒绝来自 ' + invite.senderName + ' 的传输邀请。'
        return
      }
      this.receiveTicket = invite.ticket
      this.activeSection = NavSection.RECEIVE
      this.receiveInviteStatus = '已接受邀请。请选择保存位置后手动开始接收。'
      await this.parseReceiveMetadata()
    } catch (error) {
      this.receiveInviteStatus = '处理传输邀请失败：' + (error as Error).message
    }
  }

  private async forgetPairedDevice(deviceId: string): Promise<void> {
    try {
      this.nodeOperationStatus = '正在忘记已配对设备。'
      await engineService.forgetPaired(deviceId)
      this.nodeOperationStatus = '已忘记该设备。'
    } catch (error) {
      this.nodeOperationStatus = '忘记设备失败：' + (error as Error).message
    }
  }

  private async createPairingTicket(): Promise<void> {
    try {
      this.nodeOperationStatus = '正在生成 5 分钟配对票据。'
      await engineService.startPairingHost(300)
      this.nodeOperationStatus = '配对票据已生成，接待将在 5 分钟后结束。'
    } catch (error) {
      this.nodeOperationStatus = '生成配对票据失败：' + (error as Error).message
    }
  }

  private async copyPairingTicket(): Promise<void> {
    if (this.nodeSnapshot.pairingTicket.length === 0) {
      return
    }
    try {
      let copied: boolean = await platformService.copyTicket(this.nodeSnapshot.pairingTicket)
      this.nodeOperationStatus = copied ? '配对票据已复制到系统剪贴板。' : '配对票据复制失败。'
    } catch (error) {
      this.nodeOperationStatus = '配对票据复制失败：' + (error as Error).message
    }
  }

  private async stopPairingHost(): Promise<void> {
    try {
      this.nodeOperationStatus = '正在停止配对接待。'
      await engineService.stopPairingHost()
      this.nodeOperationStatus = '配对接待已停止。'
    } catch (error) {
      this.nodeOperationStatus = '停止配对接待失败：' + (error as Error).message
    }
  }

  private async joinPairing(): Promise<void> {
    let ticket: string = this.pairingJoinTicket.trim()
    if (ticket.length === 0) {
      this.nodeOperationStatus = '请先粘贴配对票据。'
      return
    }
    try {
      this.nodeOperationStatus = '正在加入配对。'
      await engineService.joinPairing(ticket)
      this.pairingJoinTicket = ''
      this.nodeOperationStatus = '配对完成，设备列表已刷新。'
    } catch (error) {
      this.nodeOperationStatus = '加入配对失败：' + (error as Error).message
    }
  }

  @Builder
  private buildSidebar(): void {
    Column({ space: 8 }) {
      Text($r('app.string.app_name'))
        .fontSize($r('app.float.title_l'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.workbench_tagline'))
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Column({ space: 4 }) {
        this.buildNavButton(NavSection.SEND)
        this.buildNavButton(NavSection.RECEIVE)
        this.buildNavButton(NavSection.DEVICES)
        this.buildNavButton(NavSection.HISTORY)
        this.buildNavButton(NavSection.SETTINGS)
      }
      .margin({ top: 16 })

      Blank()

      this.buildNoticePanel('引擎状态', this.engineSnapshot.availability === EngineAvailability.UNAVAILABLE ? '未接入' : '可用', this.engineSnapshot.message)
    }
    .padding(16)
    .width(this.breakpoint === 'lg' ? 220 : 188)
    .height('100%')
    .backgroundColor($r('app.color.panel_surface'))
  }

  @Builder
  private buildNavButton(section: NavSection): void {
    Row() {
      Text(this.navTitle(section))
        .fontSize($r('app.float.body_m'))
        .fontColor(this.activeSection === section ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
    }
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.activeSection === section ? $r('app.color.selected_surface') : Color.Transparent)
    .borderRadius($r('app.float.radius_s'))
    .onClick(() => {
      this.activeSection = section
    })
  }

  @Builder
  private buildBottomNav(): void {
    Row() {
      this.buildBottomButton(NavSection.SEND)
      this.buildBottomButton(NavSection.RECEIVE)
      this.buildBottomButton(NavSection.DEVICES)
      this.buildBottomButton(NavSection.HISTORY)
      this.buildBottomButton(NavSection.SETTINGS)
    }
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.panel_surface'))
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  private buildBottomButton(section: NavSection): void {
    Column({ space: 4 }) {
      Text(this.navTitle(section))
        .fontSize($r('app.float.caption'))
        .fontColor(this.activeSection === section ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      this.activeSection = section
    })
  }

  @Builder
  private buildMainContent(): void {
    Scroll() {
      Column({ space: 14 }) {
        Text(this.navTitle(this.activeSection))
          .fontSize($r('app.float.title_xl'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(this.sectionSubtitle())
          .fontSize($r('app.float.body_s'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        if (this.activeSection === NavSection.SEND) {
          this.buildSendSection()
        } else if (this.activeSection === NavSection.RECEIVE) {
          this.buildReceiveSection()
        } else if (this.activeSection === NavSection.DEVICES) {
          this.buildDevicesSection()
        } else if (this.activeSection === NavSection.HISTORY) {
          this.buildHistorySection()
        } else {
          this.buildSettingsSection()
        }
      }
      .padding({ left: 16, right: 16, top: 16, bottom: this.breakpoint === 'sm' ? 20 : 16 })
      .width('100%')
    }
    .scrollBar(BarState.Auto)
    .height('100%')
    .layoutWeight(1)
  }

  @Builder
  private buildNoticePanel(title: string, status: string, detail: string): void {
    Column({ space: 6 }) {
      Text(title)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(status)
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(detail)
        .fontSize($r('app.float.caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .padding(14)
    .backgroundColor($r('app.color.subtle_warning'))
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildPlainPanel(title: string, detail: string): void {
    Column({ space: 6 }) {
      Text(title)
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(detail)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .padding(14)
    .backgroundColor($r('app.color.panel_surface'))
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildProgressPanel(progress: TransferProgress): void {
    Column({ space: 8 }) {
      Row() {
        Text(progress.title)
          .fontSize($r('app.float.body_m'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.stageLabel(progress.stage))
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.text_secondary'))
      }
      Text(progress.detail)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Progress({ value: progress.progressRatio * 100, total: 100, type: ProgressType.Linear })
        .color($r('app.color.accent'))
      if (progress.bytesLabel.length > 0 || progress.speedLabel.length > 0) {
        Row() {
          Text(progress.bytesLabel)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(progress.speedLabel)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
      }
      if (progress.ticket.length > 0) {
        Column({ space: 8 }) {
          Text('票据：' + progress.ticket)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Button('复制票据')
            .type(ButtonType.Capsule)
            .height(30)
            .onClick(() => {
              this.copyCurrentTicket()
            })
        }
      }
      if (progress.errorMessage.length > 0) {
        Text(progress.errorMessage)
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.critical'))
          .width('100%')
      }
      if ((progress.stage === TransferStage.SHARING || progress.stage === TransferStage.RECEIVING) &&
        progress.transferId.length > 0) {
        Button('取消')
          .type(ButtonType.Capsule)
          .height(30)
          .onClick(() => {
            this.cancelTransfer(progress.transferId)
          })
      }
    }
    .padding(14)
    .backgroundColor($r('app.color.panel_surface'))
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildSendSection(): void {
    Column({ space: 14 }) {
      this.buildPlainPanel('发送清单', '开始共享后会暂存所选内容，并递归计算真实字节数。')

      if (this.sendItems.length === 0) {
        this.buildPlainPanel('空态', '尚未选择任何文件或文件夹。')
      } else {
        ForEach(this.sendItems, (item: TransferItem) => {
          Row() {
            Column({ space: 2 }) {
              Text(item.name)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(item.kind + (item.sizeLabel.length > 0 ? ' · ' + item.sizeLabel : ''))
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text(item.uri)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            Button('移除')
              .type(ButtonType.Capsule)
              .height(28)
              .fontSize($r('app.float.caption'))
              .onClick(() => {
                this.sendItems = this.sendItems.filter((entry: TransferItem) => entry.id !== item.id)
                this.markSelectedState()
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (item: TransferItem) => item.id)
      }

      Row({ space: 8 }) {
        Button('选择文件')
          .layoutWeight(1)
          .onClick(() => {
            this.chooseFiles()
          })
        Button('选择文件夹（能力可用时）')
          .layoutWeight(1)
          .enabled(this.folderSelectionSupported)
          .onClick(() => {
            this.chooseFolder()
          })
      }

      Row({ space: 8 }) {
        Button('清空')
          .layoutWeight(1)
          .onClick(() => {
            this.clearSendItems()
          })
        Button('开始共享')
          .layoutWeight(1)
          .enabled(this.sendItems.length > 0 && this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.startShare()
          })
      }

      this.buildProgressPanel(this.sendState)

      if (this.sendState.stage === TransferStage.SHARING && this.sendState.ticket.length > 0) {
        Text('发送到设备')
          .fontSize($r('app.float.body_m'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        if (this.sendInviteStatus.length > 0) {
          this.buildPlainPanel('邀请状态', this.sendInviteStatus)
        }
        if (this.pairedDevices.length === 0 && this.nearbyDevices.length === 0) {
          this.buildPlainPanel('暂无目标', 'Iroh NodeService 当前没有已配对或附近设备。')
        }
        ForEach(this.pairedDevices, (device: PairedDevice) => {
          Row() {
            Column({ space: 2 }) {
              Text(device.name)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(device.deviceType + ' · ' + device.status)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .layoutWeight(1)
            Button('邀请')
              .type(ButtonType.Capsule)
              .height(30)
              .enabled(device.pairingStatus === 'active')
              .onClick(() => {
                this.inviteTransfer(device.id, true)
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (device: PairedDevice) => 'paired-' + device.id)
        ForEach(this.nearbyDevices, (device: NearbyDevice) => {
          Row() {
            Column({ space: 2 }) {
              Text(device.name)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(device.deviceType + ' · ' + device.status)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .layoutWeight(1)
            Button('邀请')
              .type(ButtonType.Capsule)
              .height(30)
              .onClick(() => {
                this.inviteTransfer(device.id, false)
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (device: NearbyDevice) => 'nearby-' + device.id)
      }
    }
  }

  @Builder
  private buildReceiveSection(): void {
    Column({ space: 14 }) {
      if (this.hasPendingTransferInvite) {
        Column({ space: 8 }) {
          Text('收到传输邀请')
            .fontSize($r('app.float.body_m'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('发送者：' + this.pendingTransferInvite.senderName)
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text(this.pendingTransferInvite.fileCount + ' 项 · ' +
            this.formatBytes(this.pendingTransferInvite.totalSize))
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Row({ space: 8 }) {
            Button('接受')
              .layoutWeight(1)
              .onClick(() => {
                this.respondToTransferInvite(true)
              })
            Button('拒绝')
              .layoutWeight(1)
              .onClick(() => {
                this.respondToTransferInvite(false)
              })
          }
        }
        .padding(14)
        .backgroundColor($r('app.color.panel_surface'))
        .borderRadius($r('app.float.radius_s'))
      }

      if (this.receiveInviteStatus.length > 0) {
        this.buildPlainPanel('邀请状态', this.receiveInviteStatus)
      }

      TextArea({ text: this.receiveTicket, placeholder: $r('app.string.ticket_placeholder') })
        .height(this.compactHeight() ? 88 : 120)
        .backgroundColor($r('app.color.panel_surface'))
        .borderRadius($r('app.float.radius_s'))
        .onChange((value: string) => {
          this.receiveTicket = value
          this.receivePreviewTitle = '尚未解析票据'
          this.receivePreviewDetail = value.trim().length > 0 ? '点击解析元数据以读取真实文件清单。' :
            '输入票据后可向发送方读取真实文件元数据。'
        })

      this.buildPlainPanel('元数据预览', this.receivePreviewTitle + '\n' + this.receivePreviewDetail)
      Button('解析元数据')
        .width('100%')
        .enabled(this.receiveTicket.trim().length > 0)
        .onClick(() => {
          this.parseReceiveMetadata()
        })

      Column({ space: 6 }) {
        Text('保存位置')
          .fontSize($r('app.float.body_s'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        this.buildPlainPanel('保存目标 URI', this.receiveFolder.length > 0 ? this.receiveFolder : '尚未选择保存位置')
        Button('选择保存位置')
          .width('100%')
          .onClick(() => {
            this.chooseReceiveTarget()
          })
      }

      Row({ space: 8 }) {
        Button('开始接收')
          .layoutWeight(1)
          .enabled(this.receiveTicket.trim().length > 0 && this.receiveFolder.length > 0 &&
            this.receiveState.stage !== TransferStage.RECEIVING)
          .onClick(() => {
            this.startReceive()
          })
        Button('清空目标')
          .layoutWeight(1)
          .onClick(() => {
            this.receiveFolder = ''
            this.resetReceiveState()
          })
      }

      this.buildProgressPanel(this.receiveState)
    }
  }

  @Builder
  private buildDevicesSection(): void {
    Column({ space: 12 }) {
      this.buildNoticePanel(
        'Iroh NodeService',
        '状态：' + this.nodeSnapshot.status,
        this.nodeSnapshot.message + '\n设备名：' +
          (this.nodeSnapshot.deviceName.length > 0 ? this.nodeSnapshot.deviceName : '尚未读取') +
          '\nEndpoint：' + (this.nodeSnapshot.endpointId.length > 0 ? this.nodeSnapshot.endpointId : '尚未读取') +
          '\n网络：' + (this.nodeSnapshot.networkReady ? '已就绪' : '未就绪')
      )
      this.buildPlainPanel('节点操作状态', this.nodeOperationStatus)

      if (this.hasPendingNearbyPairRequest) {
        Column({ space: 8 }) {
          Text('附近配对请求')
            .fontSize($r('app.float.body_m'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('发送者：' + this.pendingNearbyPairRequest.senderName)
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text('设备：' + this.pendingNearbyPairRequest.deviceType + ' · ' + this.pendingNearbyPairRequest.os)
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Row({ space: 8 }) {
            Button('接受')
              .layoutWeight(1)
              .onClick(() => {
                this.respondToNearbyPair(true, false)
              })
            Button('拒绝')
              .layoutWeight(1)
              .onClick(() => {
                this.respondToNearbyPair(false, false)
              })
          }
          Button('拒绝并阻止')
            .width('100%')
            .onClick(() => {
              this.respondToNearbyPair(false, true)
            })
        }
        .padding(14)
        .backgroundColor($r('app.color.panel_surface'))
        .borderRadius($r('app.float.radius_s'))
      }

      Text('配对票据')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.buildPlainPanel('5 分钟接待票据', this.nodeSnapshot.pairingTicket.length > 0 ?
        this.nodeSnapshot.pairingTicket : '尚未开始配对接待。')
      Row({ space: 8 }) {
        Button('生成票据')
          .layoutWeight(1)
          .enabled(this.nodeSnapshot.status === 'ready')
          .onClick(() => {
            this.createPairingTicket()
          })
        Button('停止接待')
          .layoutWeight(1)
          .enabled(this.nodeSnapshot.pairingTicket.length > 0)
          .onClick(() => {
            this.stopPairingHost()
          })
      }
      Button('复制配对票据')
        .width('100%')
        .enabled(this.nodeSnapshot.pairingTicket.length > 0)
        .onClick(() => {
          this.copyPairingTicket()
        })
      TextArea({ text: this.pairingJoinTicket, placeholder: '粘贴另一台设备生成的配对票据' })
        .height(this.compactHeight() ? 72 : 88)
        .backgroundColor($r('app.color.panel_surface'))
        .borderRadius($r('app.float.radius_s'))
        .onChange((value: string) => {
          this.pairingJoinTicket = value
        })
      Button('加入配对')
        .width('100%')
        .enabled(this.pairingJoinTicket.trim().length > 0 && this.nodeSnapshot.status === 'ready')
        .onClick(() => {
          this.joinPairing()
        })

      Text('已配对设备')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.pairedDevices.length === 0) {
        this.buildPlainPanel('空态', 'Iroh NodeService 当前没有已配对设备。')
      } else {
        ForEach(this.pairedDevices, (device: PairedDevice) => {
          Row() {
            Column({ space: 2 }) {
              Text(device.name)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(device.deviceType + (device.os.length > 0 ? ' · ' + device.os : '') +
                ' · ' + device.status + ' · ' + device.lastSeen)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .layoutWeight(1)
            Button('忘记')
              .type(ButtonType.Capsule)
              .height(30)
              .onClick(() => {
                this.forgetPairedDevice(device.id)
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (device: PairedDevice) => device.id)
      }

      Text('附近设备')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.nearbyDevices.length === 0) {
        this.buildPlainPanel('空态', 'Iroh NodeService 当前没有发现附近设备。')
      } else {
        ForEach(this.nearbyDevices, (device: NearbyDevice) => {
          Row() {
            Column({ space: 2 }) {
              Text(device.name)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(device.deviceType + (device.os.length > 0 ? ' · ' + device.os : '') +
                ' · ' + device.signalLabel + ' · ' + device.status)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text(device.fingerprint)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            Button('配对')
              .type(ButtonType.Capsule)
              .height(30)
              .onClick(() => {
                this.triggerPair(device.id)
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (device: NearbyDevice) => device.id)
      }
    }
  }

  @Builder
  private buildHistorySection(): void {
    Column({ space: 12 }) {
      if (this.historyEntries.length === 0) {
        this.buildPlainPanel('空态', '尚无真实传输历史。只有发送完成或接收内容成功导出后才会落盘记录。')
      } else {
        ForEach(this.historyEntries, (entry: HistoryEntry) => {
          Column({ space: 4 }) {
            Row() {
              Text(entry.title)
                .fontSize($r('app.float.body_m'))
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Blank()
              Text(entry.status)
                .fontSize($r('app.float.caption'))
                .fontColor($r('app.color.text_secondary'))
            }
            Text(entry.direction + ' · ' + entry.detail)
              .fontSize($r('app.float.body_s'))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text(entry.timestamp)
              .fontSize($r('app.float.caption'))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .padding(12)
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
        }, (entry: HistoryEntry) => entry.id)
      }
    }
  }

  @Builder
  private buildSettingsSection(): void {
    Column({ space: 12 }) {
      this.buildPlainPanel('节点操作状态', this.nodeOperationStatus)
      this.buildSettingField('设备名', this.settings.deviceName, '设备名', (value: string) => {
        this.updateDeviceName(value)
      })
      this.buildSettingField('主题', this.settings.theme, '主题', (value: string) => {
        this.updateTheme(value)
      })
      this.buildToggleRow('可发现性', this.settings.discoverable, (value: boolean) => {
        this.updateDiscoverable(value)
      })
      this.buildSettingField('自定义 Relay URL', this.settings.defaultRelay, '默认模式下留空', (value: string) => {
        this.updateRelay(value)
      })
      this.buildSettingField('自定义 Discovery URL', this.settings.defaultDiscovery, '默认模式下留空', (value: string) => {
        this.updateDiscovery(value)
      })
      this.buildSettingField('DNS Origin', this.settings.dnsOrigin, '默认模式下留空', (value: string) => {
        this.updateDnsOrigin(value)
      })
      this.buildToggleRow('后台恢复传输', this.settings.resumeInBackground, (value: boolean) => {
        this.updateResumeInBackground(value)
      })
      this.buildPlainPanel('关于', this.settings.about +
        '\nHarmonyOS 原生桥已接通 Rust ABI 2 传输、Iroh NodeService、配对与附近设备。' +
        '\n通知、后台任务与 App Linking 尚未实现。')
    }
  }

  @Builder
  private buildSettingField(label: string, value: string, placeholder: string, onValueChanged: (value: string) => void): void {
    Column({ space: 6 }) {
      Text(label)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .backgroundColor($r('app.color.panel_surface'))
        .borderRadius($r('app.float.radius_s'))
        .onChange((nextValue: string) => {
          onValueChanged(nextValue)
        })
    }
  }

  @Builder
  private buildToggleRow(label: string, enabled: boolean, onToggleChanged: (value: boolean) => void): void {
    Row() {
      Column({ space: 2 }) {
        Text(label)
          .fontSize($r('app.float.body_m'))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(enabled ? '已启用' : '已关闭')
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .onChange((value: boolean) => {
          onToggleChanged(value)
        })
    }
    .padding(12)
    .backgroundColor($r('app.color.panel_surface'))
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildContextPane(): void {
    Column({ space: 12 }) {
      this.buildPlainPanel('当前布局', this.breakpoint === 'lg' ? '大屏三栏：导航 + 内容 + 上下文。' : '中屏双栏：导航 + 内容。')
      this.buildPlainPanel('响应式规则', '仅由窗口宽度断点控制：sm < 600，md 600-839，lg >= 840。')
      this.buildPlainPanel('显示信息', '宽 ' + this.displayState.width + ' · 高 ' + this.displayState.height + ' · 旋转 ' + this.displayState.rotation)
      this.buildPlainPanel('折叠状态', this.displayState.isFoldable ? this.displayState.foldStatus : '当前设备不可折叠或未暴露折叠能力')
      this.buildPlainPanel('Iroh NodeService', this.nodeSnapshot.status + ' · ' +
        (this.nodeSnapshot.networkReady ? '网络已就绪' : '网络未就绪') + '\n' + this.nodeSnapshot.message)
      this.buildPlainPanel('传输引擎', this.engineSnapshot.message)
    }
    .padding(16)
    .width(240)
    .height('100%')
    .backgroundColor($r('app.color.context_surface'))
  }

  build() {
    Column() {
      if (this.breakpoint === 'sm') {
        this.buildMainContent()
        this.buildBottomNav()
      } else if (this.breakpoint === 'md') {
        Row() {
          this.buildSidebar()
          this.buildMainContent()
        }
        .layoutWeight(1)
      } else {
        Row() {
          this.buildSidebar()
          this.buildMainContent()
          this.buildContextPane()
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.updateBreakpoint(Number(newValue.width), Number(newValue.height))
    })
  }
}