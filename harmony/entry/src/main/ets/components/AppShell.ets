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
  TransferPeer,
  TransferProgress,
  TransferStage
} from '../models/AppModels'
import { appLinkService, AppLinkListener } from '../services/AppLinkService'
import { engineService, NodeListener } from '../services/EngineService'
import { platformService } from '../services/PlatformService'
import { systemIntegrationService } from '../services/SystemIntegrationService'

type NodeChangedCallback = (snapshot: NodeSnapshot) => void
type DevicesChangedCallback = (paired: Array<PairedDevice>, nearby: Array<NearbyDevice>) => void
type NearbyPairRequestCallback = (request: NearbyPairRequest) => void
type TransferInviteCallback = (invite: IncomingTransferInvite) => void

interface NoticePanel {
  title: string
  status: string
  detail: string
}

interface PlainPanel {
  title: string
  detail: string
}

interface ProgressPanel {
  progress: TransferProgress
}

interface SettingField {
  label: string
  value: string
  placeholder: string
  onValueChanged: (value: string) => void
}

interface ToggleRow {
  label: string
  enabled: boolean
  onToggleChanged: (value: boolean) => void
}

interface PickerRgbField {
  label: string
  value: string
  onValueChanged: (value: string) => void
}

interface TargetRow {
  target: DeviceTarget
  recipient: boolean
}

interface TaskPanel {
  progress: TransferProgress
  receive: boolean
}

class DeviceTarget extends TransferPeer {
  deviceType: string = ''
  os: string = ''
  paired: boolean = false
  online: boolean = false
}

class DeviceThread {
  id: string = ''
  name: string = ''
  deviceType: string = ''
  online: boolean = false
  entries: Array<HistoryEntry> = []
}

export class AppShellNavigation {
  onBack: () => boolean = (): boolean => false
}

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
  navigation: AppShellNavigation = new AppShellNavigation()
  @State private activeSection: NavSection = NavSection.DEVICES
  @State private returnSection: NavSection = NavSection.DEVICES
  @State private breakpoint: string = 'sm'
  @State private viewportHeight: number = 720
  @State private contentWidth: number = 330
  @State private sendItems: Array<TransferItem> = []
  @State private fileCatalog: Array<TransferItem> = []
  @State private fileCategory: string = 'photos'
  @State private selectedTarget: DeviceTarget = new DeviceTarget()
  @State private receivePeer: TransferPeer = new TransferPeer()
  @State private showDeviceSheet: boolean = false
  @State private activeThreadId: string = ''
  @State private pairedDevices: Array<PairedDevice> = []
  @State private nearbyDevices: Array<NearbyDevice> = []
  @State private historyEntries: Array<HistoryEntry> = []
  @State private settings: AppSettings = new AppSettings()
  @State private themeAccent: string = '#226250'
  @State private themeSelected: string = '#33226250'
  @State private themeTint: string = '#24226250'
  @State private themeActionText: string = '#FFFFFF'
  @State private showColorPicker: boolean = false
  @State private pickerEditing: boolean = false
  @State private pickerHue: number = 0
  @State private pickerWhiteness: number = 0
  @State private pickerBrightness: number = 1
  @State private pickerPlaneWidth: number = 220
  @State private pickerBaseColor: string = '#FF0000'
  @State private pickerPreview: string = '#226250'
  @State private redInput: string = '34'
  @State private greenInput: string = '98'
  @State private blueInput: string = '80'
  @State private colorError: string = ''
  @State private notificationEnabled: boolean = false
  @State private displayState: DisplayState = new DisplayState()
  @State private engineSnapshot: EngineSnapshot = new EngineSnapshot()
  @State private nodeSnapshot: NodeSnapshot = new NodeSnapshot()
  @State private sendState: TransferProgress = new TransferProgress()
  @State private receiveState: TransferProgress = new TransferProgress()
  @State private receiveTicket: string = ''
  @State private receiveFolder: string = ''
  @State private receivePreviewTitle: string = '尚未解析票据'
  @State private receivePreviewDetail: string = '输入票据后可向发送方读取真实文件元数据。'
  @State private nodeOperationStatus: string = ''
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
    this.receivePeer = new TransferPeer()
    this.openSecondary(NavSection.RECEIVE)
    this.parseReceiveMetadata().catch((error: Error): void => {
      this.receivePreviewTitle = '元数据解析失败'
      this.receivePreviewDetail = error.message
    })
  }

  aboutToAppear(): void {
    this.navigation.onBack = (): boolean => this.handleBack()
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
    this.navigation.onBack = (): boolean => false
    engineService.unsubscribeNode(this.nodeListener)
    platformService.unsubscribeDisplay(this.displayListener)
    appLinkService.unsubscribe(this.appLinkListener)
  }

  private async loadInitialState(): Promise<void> {
    try {
      this.folderSelectionSupported = platformService.isFolderSelectionSupported()
      this.settings = await platformService.loadSettings()
      this.applyAccent(this.settings.accentColor)
      await engineService.initializeNode()
      this.nodeSnapshot = engineService.getNodeSnapshot()
      this.pairedDevices = await engineService.listPairedDevices()
      this.nearbyDevices = await engineService.listNearbyDevices()
      this.historyEntries = await engineService.listHistory()
      this.displayState = platformService.getDisplayState()
      try {
        this.notificationEnabled = await systemIntegrationService.isNotificationEnabled()
      } catch (_error) {
        this.notificationEnabled = false
      }
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
    if (this.sendState.stage === TransferStage.SHARING) {
      return
    }
    try {
      let items: Array<TransferItem> = await platformService.selectFiles()
      this.addPickedItems(items, 'all')
    } catch (error) {
      let progress: TransferProgress = new TransferProgress()
      progress.stage = TransferStage.ERROR
      progress.title = '选择文件失败'
      progress.detail = '无法打开文件选择器。'
      progress.errorMessage = (error as Error).message
      this.sendState = progress
    }
  }

  private async chooseFolder(): Promise<void> {
    if (this.sendState.stage === TransferStage.SHARING) {
      return
    }
    try {
      let items: Array<TransferItem> = await platformService.selectFolder()
      this.addPickedItems(items, 'documents')
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
    if (this.sendState.stage === TransferStage.SHARING) {
      return
    }
    this.sendItems = []
    this.resetSendState()
  }

  private addPickedItems(items: Array<TransferItem>, category: string): void {
    if (items.length === 0 || this.sendState.stage === TransferStage.SHARING) {
      return
    }
    items.forEach((item: TransferItem): void => {
      if (!this.fileCatalog.some((entry: TransferItem) => entry.id === item.id)) {
        this.fileCatalog = [...this.fileCatalog, item]
      }
      if (!this.sendItems.some((entry: TransferItem) => entry.id === item.id)) {
        this.sendItems = [...this.sendItems, item]
      }
    })
    this.fileCategory = category
    this.markSelectedState()
  }

  private async choosePhotos(): Promise<void> {
    if (this.sendState.stage === TransferStage.SHARING) {
      return
    }
    try {
      this.addPickedItems(await platformService.selectPhotos(), 'photos')
    } catch (error) {
      let progress: TransferProgress = new TransferProgress()
      progress.stage = TransferStage.ERROR
      progress.title = '选择照片失败'
      progress.errorMessage = (error as Error).message
      this.sendState = progress
    }
  }

  private isPhoto(item: TransferItem): boolean {
    return item.kind === '照片' || /\.(jpg|jpeg|png|webp|heic|gif|bmp)$/i.test(item.name)
  }

  private isSelected(item: TransferItem): boolean {
    return this.sendItems.some((entry: TransferItem) => entry.id === item.id)
  }

  private photoGridHeight(): number {
    let rows: number = Math.ceil(this.fileCatalog.filter((item: TransferItem) => this.isPhoto(item)).length / 3)
    return rows * ((this.contentWidth - 8) / 3 + 4) - 4
  }

  private toggleFile(item: TransferItem): void {
    if (this.sendState.stage === TransferStage.SHARING) {
      return
    }
    this.sendItems = this.isSelected(item) ?
      this.sendItems.filter((entry: TransferItem) => entry.id !== item.id) : [...this.sendItems, item]
    this.markSelectedState()
  }

  private selectionSize(): string {
    if (this.sendItems.some((item: TransferItem) => item.sizeLabel.length === 0 || item.kind === '文件夹')) {
      return '大小待确认'
    }
    return this.formatBytes(this.sendItems.reduce((total: number, item: TransferItem) => total + item.sizeBytes, 0))
  }

  private deviceTargets(): Array<DeviceTarget> {
    let targets: Array<DeviceTarget> = this.pairedDevices.map((device: PairedDevice): DeviceTarget => {
      let target: DeviceTarget = new DeviceTarget()
      target.id = device.id
      target.name = device.name
      target.deviceType = device.deviceType
      target.os = device.os
      target.paired = true
      target.online = device.online && device.pairingStatus === 'active'
      return target
    })
    this.nearbyDevices.forEach((device: NearbyDevice): void => {
      if (!targets.some((target: DeviceTarget) => target.id === device.id)) {
        let target: DeviceTarget = new DeviceTarget()
        target.id = device.id
        target.name = device.name
        target.deviceType = device.deviceType
        target.os = device.os
        target.online = true
        targets.push(target)
      }
    })
    return targets
  }

  private deviceIcon(deviceType: string): Resource {
    let type: string = deviceType.toLowerCase()
    if (/tablet|pad/.test(type)) {
      return $r('app.media.ux_tablet')
    }
    if (/computer|desktop|laptop|pc|mac/.test(type)) {
      return $r('app.media.ux_laptop')
    }
    return $r('app.media.ux_phone')
  }

  private targetKey(target: DeviceTarget): string {
    return target.id + ':' + target.name + ':' + target.deviceType + ':' + target.os + ':' + target.online
  }

  private navIcon(section: NavSection): Resource {
    return section === NavSection.DEVICES ? $r('app.media.ux_wifi') :
      section === NavSection.SEND ? $r('app.media.ux_plus') : $r('app.media.ux_transfer')
  }

  private navSelected(section: NavSection): boolean {
    return this.activeSection === section ||
      ((this.activeSection === NavSection.RECEIVE || this.activeSection === NavSection.SETTINGS ||
      this.activeSection === NavSection.PAIRING) && this.returnSection === section)
  }

  private iconColor(color: ResourceColor): Array<number> {
    let value: number = typeof color === 'number' ? color : typeof color === 'string' ?
      Number.parseInt(color.replace('#', ''), 16) :
      this.getUIContext().getHostContext()?.resourceManager.getColorSync(color.id) ?? 0x202224
    return [
      0, 0, 0, 0, ((value >> 16) & 255) / 255,
      0, 0, 0, 0, ((value >> 8) & 255) / 255,
      0, 0, 0, 0, (value & 255) / 255,
      0, 0, 0, 1, 0
    ]
  }

  private beginDeviceTransfer(target: DeviceTarget): void {
    this.showDeviceSheet = false
    if (this.sendState.stage === TransferStage.SHARING) {
      this.activeSection = NavSection.SEND
      return
    }
    this.selectedTarget = target
    this.activeSection = NavSection.SEND
    if (this.sendItems.length === 0) {
      this.chooseFiles()
    }
  }

  private selectRecipient(target: DeviceTarget): void {
    if (!target.online || this.sendState.stage === TransferStage.SHARING) {
      return
    }
    if (this.sendItems.length === 0) {
      this.beginDeviceTransfer(target)
      return
    }
    this.selectedTarget = target
    this.showDeviceSheet = false
    this.startShare()
  }

  private deviceThreads(): Array<DeviceThread> {
    let threads: Array<DeviceThread> = []
    let targets: Array<DeviceTarget> = this.deviceTargets()
    this.historyEntries.forEach((entry: HistoryEntry): void => {
      let id: string = entry.peerId.length > 0 ? entry.peerId : 'ticket'
      let thread: DeviceThread | undefined = threads.find((item: DeviceThread) => item.id === id)
      if (thread === undefined) {
        thread = new DeviceThread()
        thread.id = id
        thread.name = entry.peerName.length > 0 ? entry.peerName : '票据传输'
        let target: DeviceTarget | undefined = targets.find((item: DeviceTarget) => item.id === id)
        if (target !== undefined) {
          thread.name = target.name
          thread.deviceType = target.deviceType
          thread.online = target.online
        }
        threads.push(thread)
      }
      thread.entries.push(entry)
    })
    targets.filter((target: DeviceTarget) => target.paired).forEach((target: DeviceTarget): void => {
      if (!threads.some((thread: DeviceThread) => thread.id === target.id)) {
        let thread: DeviceThread = new DeviceThread()
        thread.id = target.id
        thread.name = target.name
        thread.deviceType = target.deviceType
        thread.online = target.online
        threads.push(thread)
      }
    })
    return threads
  }

  private currentThread(): DeviceThread {
    return this.deviceThreads().find((thread: DeviceThread) => thread.id === this.activeThreadId) ??
      new DeviceThread()
  }

  private historyTime(timestamp: string): string {
    let date: Date = new Date(timestamp)
    if (!Number.isFinite(date.getTime())) {
      return timestamp
    }
    return (date.getMonth() + 1) + '月' + date.getDate() + '日 ' +
      date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0')
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

  private applyAccent(color: string): void {
    this.themeAccent = color
    this.themeSelected = '#33' + color.substring(1)
    this.themeTint = '#38' + color.substring(1)
    let red: number = parseInt(color.substring(1, 3), 16)
    let green: number = parseInt(color.substring(3, 5), 16)
    let blue: number = parseInt(color.substring(5, 7), 16)
    this.redInput = red.toString()
    this.greenInput = green.toString()
    this.blueInput = blue.toString()
    let redLinear: number = red / 255 <= 0.04045 ? red / 255 / 12.92 : Math.pow((red / 255 + 0.055) / 1.055, 2.4)
    let greenLinear: number = green / 255 <= 0.04045 ? green / 255 / 12.92 :
      Math.pow((green / 255 + 0.055) / 1.055, 2.4)
    let blueLinear: number = blue / 255 <= 0.04045 ? blue / 255 / 12.92 :
      Math.pow((blue / 255 + 0.055) / 1.055, 2.4)
    let luminance: number = 0.2126 * redLinear + 0.7152 * greenLinear + 0.0722 * blueLinear
    this.themeActionText = luminance > 0.179 ? '#000000' : '#FFFFFF'
    this.colorError = ''
  }

  private async saveAccent(color: string): Promise<boolean> {
    let previousColor: string = this.settings.accentColor
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.accentColor = color
    this.applyAccent(color)
    if (!await this.persistSettings(nextSettings)) {
      this.settings.accentColor = previousColor
      this.applyAccent(previousColor)
      return false
    }
    return true
  }

  private rgbHex(red: number, green: number, blue: number): string {
    return '#' + red.toString(16).padStart(2, '0') +
      green.toString(16).padStart(2, '0') + blue.toString(16).padStart(2, '0')
  }

  private setPickerFromColor(color: string, syncInputs: boolean = true): void {
    let red: number = parseInt(color.substring(1, 3), 16)
    let green: number = parseInt(color.substring(3, 5), 16)
    let blue: number = parseInt(color.substring(5, 7), 16)
    let maximum: number = Math.max(red, green, blue)
    let minimum: number = Math.min(red, green, blue)
    let difference: number = maximum - minimum
    let hue: number = 0
    if (difference > 0 && maximum === red) {
      hue = ((green - blue) / difference + 6) % 6
    } else if (difference > 0 && maximum === green) {
      hue = (blue - red) / difference + 2
    } else if (difference > 0) {
      hue = (red - green) / difference + 4
    }
    this.pickerHue = hue / 6
    this.pickerWhiteness = maximum === 0 ? 0 : minimum / maximum
    this.pickerBrightness = maximum / 255
    this.pickerPreview = color
    this.pickerBaseColor = this.pickerColorAt(1)
    if (syncInputs) {
      this.redInput = red.toString()
      this.greenInput = green.toString()
      this.blueInput = blue.toString()
    }
  }

  private pickerColorAt(brightness: number): string {
    let position: number = this.pickerHue * 6
    let segment: number = Math.min(5, Math.floor(position))
    let secondary: number = 255 * (1 - Math.abs(position % 2 - 1))
    let hueRed: number = segment === 0 || segment === 5 ? 255 :
      segment === 1 || segment === 4 ? secondary : 0
    let hueGreen: number = segment === 1 || segment === 2 ? 255 :
      segment === 0 || segment === 3 ? secondary : 0
    let hueBlue: number = segment === 3 || segment === 4 ? 255 :
      segment === 2 || segment === 5 ? secondary : 0
    let whiteness: number = this.pickerWhiteness
    return this.rgbHex(
      Math.round((hueRed * (1 - whiteness) + 255 * whiteness) * brightness),
      Math.round((hueGreen * (1 - whiteness) + 255 * whiteness) * brightness),
      Math.round((hueBlue * (1 - whiteness) + 255 * whiteness) * brightness)
    ).toUpperCase()
  }

  private updatePickerPreview(): void {
    this.pickerBaseColor = this.pickerColorAt(1)
    this.pickerPreview = this.pickerColorAt(this.pickerBrightness)
    this.redInput = parseInt(this.pickerPreview.substring(1, 3), 16).toString()
    this.greenInput = parseInt(this.pickerPreview.substring(3, 5), 16).toString()
    this.blueInput = parseInt(this.pickerPreview.substring(5, 7), 16).toString()
    this.colorError = ''
  }

  private updatePickerPlane(event: TouchEvent): void {
    if ((event.type === TouchType.Down || event.type === TouchType.Move) && event.touches.length > 0) {
      this.pickerHue = Math.max(0, Math.min(1, event.touches[0].x / this.pickerPlaneWidth))
      this.pickerWhiteness = Math.max(0, Math.min(1, event.touches[0].y / 224))
      this.updatePickerPreview()
    }
  }

  private updatePickerBrightness(event: TouchEvent): void {
    if ((event.type === TouchType.Down || event.type === TouchType.Move) && event.touches.length > 0) {
      this.pickerBrightness = 1 - Math.max(0, Math.min(1, event.touches[0].y / 224))
      this.updatePickerPreview()
    }
  }

  private previewRgbInput(): void {
    let red: number = this.parseRgbChannel(this.redInput)
    let green: number = this.parseRgbChannel(this.greenInput)
    let blue: number = this.parseRgbChannel(this.blueInput)
    if (red >= 0 && green >= 0 && blue >= 0) {
      this.setPickerFromColor(this.rgbHex(red, green, blue).toUpperCase(), false)
    }
    this.colorError = ''
  }

  private openColorPicker(): void {
    this.setPickerFromColor(this.themeAccent)
    this.colorError = ''
    this.pickerEditing = false
    this.showColorPicker = true
  }

  private parseRgbChannel(value: string): number {
    if (!/^\d{1,3}$/.test(value)) {
      return -1
    }
    let channel: number = Number(value)
    return channel >= 0 && channel <= 255 ? channel : -1
  }

  private async saveRgbColor(): Promise<void> {
    let red: number = this.parseRgbChannel(this.redInput)
    let green: number = this.parseRgbChannel(this.greenInput)
    let blue: number = this.parseRgbChannel(this.blueInput)
    if (red < 0 || green < 0 || blue < 0) {
      this.colorError = 'RGB 每项请输入 0–255 的整数。'
      return
    }
    let color: string = this.rgbHex(red, green, blue).toUpperCase()
    if (await this.saveAccent(color)) {
      this.showColorPicker = false
    } else {
      this.colorError = '保存失败，请重试。'
    }
  }

  private async updateRelay(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.defaultRelay = value
    if (await this.persistSettings(nextSettings)) {
      this.nodeOperationStatus = 'Relay 已保存；重启应用后设备节点会使用新配置。'
    }
  }

  private async updateDiscovery(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.defaultDiscovery = value
    if (await this.persistSettings(nextSettings)) {
      this.nodeOperationStatus = 'Discovery 已保存；重启应用后设备节点会使用新配置。'
    }
  }

  private async updateDnsOrigin(value: string): Promise<void> {
    let nextSettings: AppSettings = this.settings.clone()
    nextSettings.dnsOrigin = value
    if (await this.persistSettings(nextSettings)) {
      this.nodeOperationStatus = 'DNS Origin 已保存；重启应用后设备节点会使用新配置。'
    }
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

  private async updateDisplayMode(mode: string): Promise<void> {
    try {
      platformService.applyDisplayMode(mode)
      let nextSettings: AppSettings = this.settings.clone()
      nextSettings.theme = mode
      await this.persistSettings(nextSettings)
    } catch (error) {
      this.nodeOperationStatus = '显示模式切换失败：' + (error as Error).message
    }
  }

  private async enableNotifications(): Promise<void> {
    await systemIntegrationService.requestNotificationAuthorization()
    try {
      this.notificationEnabled = await systemIntegrationService.isNotificationEnabled()
      this.nodeOperationStatus = this.notificationEnabled ? '通知已开启。' : '通知未开启，可在系统设置中授权。'
    } catch (error) {
      this.nodeOperationStatus = '通知状态读取失败：' + (error as Error).message
    }
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

  private handleBack(): boolean {
    if (this.showColorPicker) {
      this.showColorPicker = false
      this.pickerEditing = false
      return true
    }
    if (this.showDeviceSheet) {
      this.showDeviceSheet = false
      return true
    }
    if (this.activeSection === NavSection.RECEIVE || this.activeSection === NavSection.SETTINGS ||
      this.activeSection === NavSection.PAIRING) {
      this.activeSection = this.returnSection
      return true
    }
    if (this.activeSection === NavSection.HISTORY && this.activeThreadId.length > 0) {
      this.activeThreadId = ''
      return true
    }
    if (this.activeSection !== NavSection.DEVICES) {
      this.activeSection = NavSection.DEVICES
      return true
    }
    return false
  }

  private selectMainSection(section: NavSection): void {
    this.activeSection = section
    if (section === NavSection.HISTORY) {
      this.activeThreadId = ''
      this.refreshHistory()
    }
  }

  private openSecondary(section: NavSection): void {
    if (this.activeSection !== NavSection.RECEIVE && this.activeSection !== NavSection.SETTINGS &&
      this.activeSection !== NavSection.PAIRING) {
      this.returnSection = this.activeSection
    }
    this.activeSection = section
  }

  private navTitle(section: NavSection): string {
    if (section === NavSection.SEND) {
      return '文件'
    }
    if (section === NavSection.RECEIVE) {
      return '接收'
    }
    if (section === NavSection.DEVICES) {
      return '附近'
    }
    if (section === NavSection.HISTORY) {
      return '往来'
    }
    if (section === NavSection.PAIRING) {
      return '设备配对'
    }
    return '设置'
  }

  private sectionSubtitle(): string {
    if (this.activeSection === NavSection.SEND) {
      return '本机内容'
    }
    if (this.activeSection === NavSection.RECEIVE) {
      return '粘贴票据，保存到这台设备。'
    }
    if (this.activeSection === NavSection.DEVICES) {
      return this.deviceTargets().filter((target: DeviceTarget) => target.online).length + ' 台设备在线'
    }
    if (this.activeSection === NavSection.HISTORY) {
      return '文件在设备之间'
    }
    return '这台设备的偏好。'
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
    if (this.sendItems.length === 0 || this.sendState.stage === TransferStage.SHARING) {
      return
    }
    let target: DeviceTarget = this.selectedTarget
    let peer: TransferPeer = new TransferPeer()
    let invited: boolean = false
    this.sendInviteStatus = ''
    let pending: TransferProgress = new TransferProgress()
    pending.stage = TransferStage.SHARING
    pending.title = '正在启动共享'
    pending.detail = '正在准备所选内容。'
    this.sendState = pending
    await engineService.send(this.sendItems, (progress: TransferProgress): void => {
      this.sendState = progress
      if (!invited && target.id.length > 0 && progress.stage === TransferStage.SHARING &&
        progress.ticket.length > 0) {
        invited = true
        this.inviteTransfer(target.id, target.paired, peer)
      }
      if (progress.stage === TransferStage.COMPLETED) {
        this.refreshHistory()
      }
    }, peer)
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
    }, this.receivePeer)
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

  private async inviteTransfer(deviceId: string, paired: boolean, peer?: TransferPeer): Promise<void> {
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
      if (delivered && peer !== undefined) {
        peer.id = deviceId
        peer.name = this.selectedTarget.name
      }
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
      let peer: TransferPeer = new TransferPeer()
      peer.id = invite.endpointId
      peer.name = invite.senderName
      this.receivePeer = peer
      this.openSecondary(NavSection.RECEIVE)
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
      Column({ space: 4 }) {
        this.buildNavButton(NavSection.DEVICES)
        this.buildNavButton(NavSection.SEND)
        this.buildNavButton(NavSection.HISTORY)
      }
      .margin({ top: 16 })

      Blank()

      Text(this.nodeSnapshot.networkReady ? '网络已连接' : '网络未连接')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .padding(16)
    .width(this.breakpoint === 'lg' ? 220 : 188)
    .height('100%')
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: { right: 1 }, color: $r('app.color.glass_edge') })
  }

  @Builder
  private buildNavButton(section: NavSection): void {
    Button() {
      Row({ space: 12 }) {
        Image(this.navIcon(section))
          .width(22)
          .height(22)
          .colorFilter(this.iconColor(this.navSelected(section) ? this.themeAccent : $r('app.color.text_secondary')))
      Text(this.navTitle(section))
        .fontSize($r('app.float.body_m'))
        .fontColor(this.navSelected(section) ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
      }
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.navSelected(section) ? this.themeSelected : Color.Transparent)
    .animation({ duration: 180, curve: Curve.EaseOut })
    .borderRadius($r('app.float.radius_s'))
    .onClick(() => {
      this.selectMainSection(section)
    })
  }

  @Builder
  private buildAppHeader(): void {
    Row({ space: 8 }) {
      if (this.activeSection === NavSection.RECEIVE || this.activeSection === NavSection.SETTINGS ||
        this.activeSection === NavSection.PAIRING ||
        (this.activeSection === NavSection.HISTORY && this.activeThreadId.length > 0)) {
        Button() {
          Image($r('app.media.ux_chevron'))
            .width(22)
            .height(22)
            .rotate({ angle: 180 })
            .colorFilter(this.iconColor($r('app.color.text_primary')))
        }
          .type(ButtonType.Normal)
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .accessibilityText('返回')
          .onClick(() => {
            if (this.activeSection === NavSection.HISTORY) {
              this.activeThreadId = ''
            } else {
              this.activeSection = this.returnSection
            }
          })
      } else {
        Image($r('app.media.dashbeam_logo'))
          .width(24)
          .height(24)
          .borderRadius(5)
      }
      Text('DashBeam')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.activeSection === NavSection.DEVICES) {
        Button() {
          Image($r('app.media.ux_plus')).width(22).height(22).colorFilter(this.iconColor($r('app.color.text_primary')))
        }
        .type(ButtonType.Normal)
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText('添加设备')
        .onClick(() => {
          this.openSecondary(NavSection.PAIRING)
        })
      }
      Button() {
        Image($r('app.media.ux_receive')).width(22).height(22).colorFilter(this.iconColor($r('app.color.text_primary')))
      }
        .type(ButtonType.Normal)
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText('接收文件')
        .onClick(() => {
          this.openSecondary(NavSection.RECEIVE)
        })
      Button() {
        Image($r('app.media.ux_settings')).width(22).height(22).colorFilter(this.iconColor($r('app.color.text_primary')))
      }
        .type(ButtonType.Normal)
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText('设置')
        .onClick(() => {
          this.openSecondary(NavSection.SETTINGS)
        })
    }
    .padding({ left: 20, right: 12 })
    .height(60)
    .width('100%')
    .backgroundColor($r('app.color.glass_surface'))
    .bindSheet(this.showDeviceSheet, this.buildDeviceSheet(), {
      height: SheetSize.LARGE,
      backgroundColor: $r('app.color.app_background'),
      onDisappear: () => {
        this.showDeviceSheet = false
      }
    })
  }

  @Builder
  private buildBottomNav(): void {
    Row() {
      this.buildBottomButton(NavSection.DEVICES)
      this.buildBottomButton(NavSection.SEND)
      this.buildBottomButton(NavSection.HISTORY)
    }
    .padding({ left: 18, right: 18, top: 4, bottom: 6 })
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  private buildBottomButton(section: NavSection): void {
    Button() {
      Column({ space: 5 }) {
      Image(this.navIcon(section))
        .width(22)
        .height(22)
        .colorFilter(this.iconColor(this.navSelected(section) ? this.themeAccent : $r('app.color.text_secondary')))
      Text(this.navTitle(section))
        .fontSize($r('app.float.body_s'))
        .fontWeight(this.navSelected(section) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.navSelected(section) ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .type(ButtonType.Normal)
    .layoutWeight(1)
    .height(60)
    .backgroundColor(Color.Transparent)
    .accessibilityText(this.navTitle(section) + (this.navSelected(section) ? '，已选中' : ''))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .borderRadius($r('app.float.radius_s'))
    .onClick(() => {
      this.selectMainSection(section)
    })
  }

  @Builder
  private buildMainContent(): void {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 4 }) {
          Text(this.activeSection === NavSection.RECEIVE ? '接收文件' :
            this.activeSection === NavSection.HISTORY && this.activeThreadId.length > 0 ?
            this.currentThread().name : this.navTitle(this.activeSection))
            .fontSize($r('app.float.title_xl'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .width('100%')
          Text(this.sectionSubtitle())
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 12, bottom: 8 })
        .width('100%')

        if (this.activeSection === NavSection.SEND) {
          this.buildSendSection()
        } else if (this.activeSection === NavSection.RECEIVE) {
          this.buildReceiveSection()
        } else if (this.activeSection === NavSection.DEVICES) {
          this.buildDevicesSection()
        } else if (this.activeSection === NavSection.HISTORY) {
          this.buildHistorySection()
        } else if (this.activeSection === NavSection.PAIRING) {
          this.buildPairingSection()
        } else {
          this.buildSettingsSection()
        }
      }
      .justifyContent(FlexAlign.Start)
      .padding({ left: 22, right: 22, top: 0, bottom: 24 })
      .constraintSize({ maxWidth: 760 })
      .width('100%')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.contentWidth = Math.max(120, Number(newValue.width) - 44)
      })
    }
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .height('100%')
    .layoutWeight(1)
  }

  @Builder
  private buildNoticePanel(panel: NoticePanel): void {
    Column({ space: 6 }) {
      Text(panel.title)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(panel.status)
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(panel.detail)
        .fontSize($r('app.float.caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .padding(14)
    .backgroundColor($r('app.color.subtle_warning'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildPlainPanel(panel: PlainPanel): void {
    Column({ space: 6 }) {
      Text(panel.title)
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(panel.detail)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .padding(16)
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildProgressPanel(panel: ProgressPanel): void {
    Column({ space: 8 }) {
      Row() {
        Text(panel.progress.title)
          .fontSize($r('app.float.body_m'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.stageLabel(panel.progress.stage))
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.text_secondary'))
      }
      Text(panel.progress.detail)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Progress({ value: panel.progress.progressRatio * 100, total: 100, type: ProgressType.Linear })
        .color(this.themeAccent)
        .style({ enableSmoothEffect: true })
      if (panel.progress.bytesLabel.length > 0 || panel.progress.speedLabel.length > 0) {
        Row() {
          Text(panel.progress.bytesLabel)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(panel.progress.speedLabel)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }
      if (panel.progress.ticket.length > 0) {
        Column({ space: 8 }) {
          Text('票据：' + panel.progress.ticket)
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Button('复制票据')
            .type(ButtonType.Normal)
            .height(44)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(this.themeSelected)
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.copyCurrentTicket()
            })
        }
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }
      if (panel.progress.errorMessage.length > 0) {
        Text(panel.progress.errorMessage)
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.critical'))
          .width('100%')
          .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }
      if ((panel.progress.stage === TransferStage.SHARING || panel.progress.stage === TransferStage.RECEIVING) &&
        panel.progress.transferId.length > 0) {
        Button('取消')
          .type(ButtonType.Normal)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .borderRadius($r('app.float.radius_s'))
          .onClick(() => {
            this.cancelTransfer(panel.progress.transferId)
          })
      }
    }
    .padding(16)
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
    .shadow({ radius: 14, color: $r('app.color.glass_shadow'), offsetX: 0, offsetY: 4 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildSendSection(): void {
    Column({ space: 14 }) {
      Row({ space: 24 }) {
        ForEach(['photos', 'documents', 'all'], (category: string) => {
          Button(category === 'photos' ? '照片' : category === 'documents' ? '文档' : '全部')
            .type(ButtonType.Normal)
            .height(44)
            .fontSize(14)
            .fontWeight(this.fileCategory === category ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.fileCategory === category ? $r('app.color.text_primary') :
              $r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .border({ width: { bottom: 2 }, color: this.fileCategory === category ?
              this.themeAccent : Color.Transparent })
            .onClick(() => {
              this.fileCategory = category
            })
        }, (category: string) => category)
      }
      .width('100%')
      .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
      Row({ space: 8 }) {
        Button('添加照片')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.choosePhotos()
          })
        Button('添加文件')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius($r('app.float.radius_s'))
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.chooseFiles()
          })
      }
      if (this.fileCategory !== 'documents' && this.fileCatalog.some((item: TransferItem) => this.isPhoto(item))) {
        Grid() {
          ForEach(this.fileCatalog.filter((item: TransferItem) => this.isPhoto(item)), (item: TransferItem) => {
            GridItem() {
              Button() {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(item.uri)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                  Text(this.isSelected(item) ? (this.sendItems.findIndex((entry: TransferItem) =>
                    entry.id === item.id) + 1).toString() : '')
                    .fontSize(12)
                    .fontColor(this.themeActionText)
                    .width(22)
                    .height(22)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.isSelected(item) ? this.themeAccent : '#66000000')
                    .border({ width: 1, color: '#FFFFFF' })
                    .borderRadius(11)
                    .margin(8)
                }
              }
              .type(ButtonType.Normal)
              .padding(0)
              .width('100%')
              .aspectRatio(1)
              .borderRadius(4)
              .border({ width: this.isSelected(item) ? 3 : 0, color: this.themeAccent })
              .accessibilityText(item.name + (this.isSelected(item) ? '，已选择' : '，未选择'))
              .enabled(this.sendState.stage !== TransferStage.SHARING)
              .onClick(() => {
                this.toggleFile(item)
              })
            }
          }, (item: TransferItem) => item.id)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(4)
        .rowsGap(4)
        .width('100%')
        .height(this.photoGridHeight())
      }
      if (this.fileCategory !== 'photos') {
        ForEach(this.fileCatalog.filter((item: TransferItem) => !this.isPhoto(item)), (item: TransferItem) => {
          Button() {
            Row({ space: 12 }) {
              Text(item.kind === '文件夹' ? 'DIR' : item.name.split('.').pop()?.toUpperCase().slice(0, 4) ?? 'FILE')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width(38)
                .height(46)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.panel_surface'))
                .borderRadius(4)
              Column({ space: 5 }) {
                Text(item.name)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(item.kind !== '文件夹' && item.sizeLabel.length > 0 ? this.formatBytes(item.sizeBytes) : item.kind)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
              .layoutWeight(1)
              Text(this.isSelected(item) ? '✓' : '')
                .width(22)
                .height(22)
                .fontSize(13)
                .textAlign(TextAlign.Center)
                .fontColor(this.themeActionText)
                .backgroundColor(this.isSelected(item) ? this.themeAccent : Color.Transparent)
                .border({ width: 1, color: this.isSelected(item) ? this.themeAccent : $r('app.color.divider') })
                .borderRadius(11)
            }
            .padding({ top: 12, bottom: 12 })
          }
          .type(ButtonType.Normal)
          .width('100%')
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
          .accessibilityText(item.name + (this.isSelected(item) ? '，已选择' : '，未选择'))
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.toggleFile(item)
          })
        }, (item: TransferItem) => item.id)
      }
      if (!this.fileCatalog.some((item: TransferItem) => this.fileCategory === 'all' ||
        (this.fileCategory === 'photos' ? this.isPhoto(item) : !this.isPhoto(item)))) {
        Column({ space: 12 }) {
          Image($r('app.media.ux_plus')).width(32).height(32).colorFilter(this.iconColor($r('app.color.text_secondary')))
          Text(this.fileCategory === 'photos' ? '尚未添加照片' : '尚未添加文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 48, bottom: 48 })
      }
      if (this.folderSelectionSupported) {
        Button('添加文件夹')
          .type(ButtonType.Normal)
          .height(44)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.radius_s'))
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.chooseFolder()
          })
      }
      if (this.sendState.stage !== TransferStage.IDLE && this.sendState.stage !== TransferStage.SELECTED) {
        this.buildProgressPanel({ progress: this.sendState })
      }
      if (this.sendInviteStatus.length > 0) {
        Text(this.sendInviteStatus).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
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
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(44)
              .fontColor(this.themeActionText)
              .backgroundColor(this.themeAccent)
              .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
              .borderRadius($r('app.float.radius_s'))
              .onClick(() => {
                this.respondToTransferInvite(true)
              })
            Button('拒绝')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(44)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor(this.themeSelected)
              .borderRadius($r('app.float.radius_s'))
              .onClick(() => {
                this.respondToTransferInvite(false)
              })
          }
        }
        .padding(14)
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }

      if (this.receiveInviteStatus.length > 0) {
        this.buildPlainPanel({ title: '邀请状态', detail: this.receiveInviteStatus })
      }

      Text('分享票据')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextArea({ text: this.receiveTicket, placeholder: $r('app.string.ticket_placeholder') })
        .height(this.compactHeight() ? 84 : 104)
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .onChange((value: string) => {
          this.receiveTicket = value
          this.receivePeer = new TransferPeer()
          this.receivePreviewTitle = '尚未解析票据'
          this.receivePreviewDetail = value.trim().length > 0 ? '点击解析元数据以读取真实文件清单。' :
            '输入票据后可向发送方读取真实文件元数据。'
        })

      Button('解析元数据')
        .type(ButtonType.Normal)
        .width('100%')
        .height(44)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor(this.themeSelected)
        .borderRadius($r('app.float.radius_s'))
        .enabled(this.receiveTicket.trim().length > 0)
        .onClick(() => {
          this.parseReceiveMetadata()
        })
      if (this.receiveTicket.trim().length > 0) {
        this.buildPlainPanel({ title: '文件预览', detail: this.receivePreviewTitle + '\n' + this.receivePreviewDetail })
      }

      Row({ space: 10 }) {
        Column({ space: 5 }) {
          Text('保存位置')
            .fontSize($r('app.float.body_m'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.receiveFolder.length > 0 ? this.receiveFolder : '尚未选择保存位置')
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('选择位置')
          .type(ButtonType.Normal)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .borderRadius($r('app.float.radius_s'))
          .onClick(() => {
            this.chooseReceiveTarget()
          })
      }
      .padding(14)
      .backgroundColor($r('app.color.glass_surface'))
      .border({ width: 1, color: $r('app.color.glass_edge') })
      .borderRadius($r('app.float.radius_s'))

      Button('开始接收')
        .type(ButtonType.Normal)
        .width('100%')
        .height(44)
        .fontColor(this.receiveTicket.trim().length > 0 && this.receiveFolder.length > 0 &&
          this.receiveState.stage !== TransferStage.RECEIVING ?
          this.themeActionText : $r('app.color.text_secondary'))
        .backgroundColor(this.receiveTicket.trim().length > 0 && this.receiveFolder.length > 0 &&
          this.receiveState.stage !== TransferStage.RECEIVING ?
          this.themeAccent : this.themeSelected)
        .border({ width: this.receiveTicket.trim().length > 0 && this.receiveFolder.length > 0 &&
          this.receiveState.stage !== TransferStage.RECEIVING && this.themeActionText === '#000000' ? 1 : 0,
          color: '#000000' })
        .borderRadius($r('app.float.radius_s'))
        .enabled(this.receiveTicket.trim().length > 0 && this.receiveFolder.length > 0 &&
          this.receiveState.stage !== TransferStage.RECEIVING)
        .onClick(() => {
          this.startReceive()
        })
      Button('清空目标')
        .type(ButtonType.Normal)
        .height(44)
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent)
        .borderRadius($r('app.float.radius_s'))
        .enabled(this.receiveFolder.length > 0)
        .onClick(() => {
          this.receiveFolder = ''
          this.resetReceiveState()
        })

      if (this.receiveState.stage !== TransferStage.IDLE) {
        this.buildProgressPanel({ progress: this.receiveState })
      }
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildDevicesSection(): void {
    Column({ space: 16 }) {
      Row() {
        Text('我的设备').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Blank()
        Text('已配对').fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      if (this.pairedDevices.length === 0) {
        Text('还没有已配对设备')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .padding({ top: 20, bottom: 20 })
          .width('100%')
      } else {
        Grid() {
          ForEach(this.deviceTargets().filter((target: DeviceTarget) => target.paired), (target: DeviceTarget) => {
            GridItem() {
              Button() {
                Column({ space: 10 }) {
                  Image(this.deviceIcon(target.deviceType))
                    .width(36)
                    .height(36)
                    .colorFilter(this.iconColor($r('app.color.text_primary')))
                  Text(target.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text((target.online ? '在线' : '离线') + (target.os.length > 0 ? ' · ' + target.os : ''))
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .justifyContent(FlexAlign.Start)
                .width('100%')
              }
              .type(ButtonType.Normal)
              .width('100%')
              .height(148)
              .padding(16)
              .backgroundColor($r('app.color.panel_surface'))
              .border({ width: 1, color: $r('app.color.divider') })
              .borderRadius(8)
              .enabled(target.online)
              .accessibilityText(target.name + (target.online ? '，在线，发送文件' : '，离线'))
              .onClick(() => {
                this.beginDeviceTransfer(target)
              })
            }
          }, (target: DeviceTarget) => this.targetKey(target))
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
        .height(Math.ceil(this.pairedDevices.length / 2) * 158 - 10)
      }
      Text('其他设备')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ top: 8 })
      if (!this.deviceTargets().some((target: DeviceTarget) => !target.paired)) {
        Column({ space: 14 }) {
          Image($r('app.media.ux_wifi')).width(32).height(32).colorFilter(this.iconColor($r('app.color.text_secondary')))
          Text(this.settings.discoverable ? '附近暂无其他设备' : '附近发现已关闭')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 36 })
      }
      ForEach(this.deviceTargets().filter((target: DeviceTarget) => !target.paired), (target: DeviceTarget) => {
        this.buildTargetRow({ target: target, recipient: false })
      }, (target: DeviceTarget) => this.targetKey(target))
      Row({ space: 12 }) {
        Image($r('app.media.ux_phone')).width(22).height(22).colorFilter(this.iconColor($r('app.color.text_primary')))
        Column({ space: 5 }) {
          Text(this.settings.deviceName).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
          Text((this.settings.discoverable ? '附近设备可发现' : '已关闭附近发现') + ' · 本机')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 20 })
      .border({ width: { top: 1 }, color: $r('app.color.divider') })
    }
    .width('100%')
  }

  @Builder
  private buildTargetRow(row: TargetRow): void {
    Button() {
      Row({ space: 12 }) {
        Image(this.deviceIcon(row.target.deviceType))
          .width(28)
          .height(28)
          .colorFilter(this.iconColor($r('app.color.text_primary')))
        Column({ space: 5 }) {
          Text(row.target.name)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text((row.target.os.length > 0 ? row.target.os + ' · ' : '') + (row.target.online ? '在线' : '离线'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        Image($r('app.media.ux_chevron')).width(18).height(18).colorFilter(this.iconColor($r('app.color.text_secondary')))
      }
      .padding({ top: 16, bottom: 16 })
    }
    .type(ButtonType.Normal)
    .padding(0)
    .width('100%')
    .backgroundColor(Color.Transparent)
    .borderRadius(0)
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
    .enabled(row.target.online)
    .onClick(() => {
      if (row.recipient) {
        this.selectRecipient(row.target)
      } else {
        this.beginDeviceTransfer(row.target)
      }
    })
  }

  @Builder
  private buildDeviceSheet(): void {
    Scroll() {
      Column({ space: 14 }) {
        Text('发送到').fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
        Text(this.sendItems.length > 0 ? '已选 ' + this.sendItems.length + ' 项 · ' + this.selectionSize() : '附近设备')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        ForEach(this.deviceTargets(), (target: DeviceTarget) => {
          this.buildTargetRow({ target: target, recipient: true })
        }, (target: DeviceTarget) => this.targetKey(target))
        if (this.deviceTargets().length === 0) {
          Text('暂无在线设备').fontSize(14).fontColor($r('app.color.text_secondary')).padding({ top: 32, bottom: 32 })
        }
        Button(this.sendItems.length > 0 ? '使用分享票据' : '选择文件')
          .type(ButtonType.Normal)
          .height(48)
          .width('100%')
          .fontColor(this.themeActionText)
          .backgroundColor(this.themeAccent)
          .borderRadius(6)
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.selectedTarget = new DeviceTarget()
            this.showDeviceSheet = false
            this.activeSection = NavSection.SEND
            if (this.sendItems.length > 0) {
              this.startShare()
            } else {
              this.chooseFiles()
            }
          })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 20, bottom: 32 })
    }
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
  }

  @Builder
  private buildTaskStrip(): void {
    if (this.sendState.stage === TransferStage.SHARING) {
      this.buildActiveTask({ progress: this.sendState, receive: false })
    }
    if (this.receiveState.stage === TransferStage.RECEIVING) {
      this.buildActiveTask({ progress: this.receiveState, receive: true })
    }
  }

  @Builder
  private buildActiveTask(task: TaskPanel): void {
    Button() {
      Row({ space: 12 }) {
        Image($r('app.media.ux_transfer')).width(22).height(22).colorFilter(this.iconColor(this.themeAccent))
        Column({ space: 4 }) {
          Text(task.progress.title).fontSize(13).fontColor($r('app.color.text_primary')).width('100%')
          Text(task.progress.bytesLabel.length > 0 ? task.progress.bytesLabel : task.progress.detail)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        Text(Math.round(task.progress.progressRatio * 100) + '%').fontSize(16).fontColor($r('app.color.text_primary'))
      }
      .padding({ left: 22, right: 22, top: 12, bottom: 12 })
    }
    .type(ButtonType.Normal)
    .padding(0)
    .width('100%')
    .backgroundColor(this.themeSelected)
    .borderRadius(0)
    .onClick(() => {
      if (task.receive) {
        this.openSecondary(NavSection.RECEIVE)
      } else {
        this.activeSection = NavSection.SEND
      }
    })
  }

  @Builder
  private buildActionBar(): void {
    if (this.activeSection === NavSection.DEVICES) {
      Row({ space: 10 }) {
        Button('接收')
          .type(ButtonType.Normal)
          .height(48)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.panel_surface'))
          .borderRadius(6)
          .onClick(() => {
            this.openSecondary(NavSection.RECEIVE)
          })
        Button('选择文件')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(48)
          .fontColor(this.themeActionText)
          .backgroundColor(this.themeAccent)
          .borderRadius(6)
          .enabled(this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.beginDeviceTransfer(new DeviceTarget())
          })
      }
      .padding({ left: 22, right: 22, top: 12, bottom: 12 })
      .width('100%')
      .backgroundColor($r('app.color.glass_surface'))
    } else if (this.activeSection === NavSection.SEND) {
      Column({ space: 10 }) {
        Row() {
          Text('已选 ' + this.sendItems.length + ' 项').fontSize(13).fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.selectionSize()).fontSize(12).fontColor($r('app.color.text_secondary'))
          Button() {
            Image($r('app.media.ux_close')).width(18).height(18).colorFilter(this.iconColor($r('app.color.text_secondary')))
          }
          .type(ButtonType.Normal)
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .accessibilityText('清空选择')
          .enabled(this.sendItems.length > 0 && this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            this.clearSendItems()
          })
        }
        .width('100%')
        if (this.selectedTarget.id.length > 0) {
          Row() {
            Text('发给 ' + this.selectedTarget.name)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Button('更换')
              .type(ButtonType.Normal)
              .height(44)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor(Color.Transparent)
              .enabled(this.sendState.stage !== TransferStage.SHARING)
              .onClick(() => {
                this.showDeviceSheet = true
              })
          }
        }
        Button('发送' + (this.sendItems.length > 0 ? ' ' + this.sendItems.length + ' 项' : ''))
          .type(ButtonType.Normal)
          .width('100%')
          .height(48)
          .fontColor(this.themeActionText)
          .backgroundColor(this.themeAccent)
          .borderRadius(6)
          .enabled(this.sendItems.length > 0 && this.sendState.stage !== TransferStage.SHARING)
          .onClick(() => {
            if (this.selectedTarget.id.length > 0) {
              this.startShare()
            } else {
              this.showDeviceSheet = true
            }
          })
      }
      .padding({ left: 22, right: 22, top: 4, bottom: 12 })
      .width('100%')
      .backgroundColor($r('app.color.glass_surface'))
      .border({ width: { top: 1 }, color: $r('app.color.divider') })
    } else if (this.activeSection === NavSection.HISTORY && this.activeThreadId.length === 0) {
      Row() {
        Button('新的传输')
        .type(ButtonType.Normal)
        .layoutWeight(1)
        .height(48)
        .fontColor(this.themeActionText)
        .backgroundColor(this.themeAccent)
        .borderRadius(6)
        .enabled(this.sendState.stage !== TransferStage.SHARING)
        .onClick(() => {
          this.showDeviceSheet = true
        })
      }
      .padding({ left: 22, right: 22, top: 12, bottom: 12 })
      .width('100%')
    }
  }

  @Builder
  private buildPairingSection(): void {
    Column({ space: 12 }) {
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
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(44)
              .fontColor(this.themeActionText)
              .backgroundColor(this.themeAccent)
              .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
              .borderRadius($r('app.float.radius_s'))
              .onClick(() => {
                this.respondToNearbyPair(true, false)
              })
            Button('拒绝')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(44)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor(this.themeSelected)
              .borderRadius($r('app.float.radius_s'))
              .onClick(() => {
                this.respondToNearbyPair(false, false)
              })
          }
          Button('拒绝并阻止')
            .type(ButtonType.Normal)
            .width('100%')
            .height(44)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(this.themeSelected)
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.respondToNearbyPair(false, true)
            })
        }
        .padding(14)
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }

      if (this.nodeOperationStatus.length > 0) {
        this.buildPlainPanel({ title: '设备状态', detail: this.nodeOperationStatus })
      }

      this.buildNearbyDevices()

      Text('已配对设备')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.pairedDevices.length === 0) {
        this.buildPlainPanel({ title: '还没有已配对设备', detail: '可从附近设备中选择并配对。' })
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
              .type(ButtonType.Normal)
              .height(44)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor(this.themeSelected)
              .borderRadius($r('app.float.radius_s'))
              .onClick(() => {
                this.forgetPairedDevice(device.id)
              })
          }
          .padding(12)
          .backgroundColor($r('app.color.glass_surface'))
          .border({ width: 1, color: $r('app.color.glass_edge') })
          .borderRadius($r('app.float.radius_s'))
          .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
        }, (device: PairedDevice) => device.id)
      }

      Text('配对票据')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.buildPlainPanel({ title: '5 分钟接待票据', detail: this.nodeSnapshot.pairingTicket.length > 0 ?
        this.nodeSnapshot.pairingTicket : '尚未开始配对接待。' })
      Row({ space: 8 }) {
        Button('生成票据')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(44)
          .fontColor(this.themeActionText)
          .backgroundColor(this.themeAccent)
          .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
          .borderRadius($r('app.float.radius_s'))
          .enabled(this.nodeSnapshot.status === 'ready')
          .onClick(() => {
            this.createPairingTicket()
          })
        Button('停止接待')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .borderRadius($r('app.float.radius_s'))
          .enabled(this.nodeSnapshot.pairingTicket.length > 0)
          .onClick(() => {
            this.stopPairingHost()
          })
      }
      Button('复制配对票据')
        .type(ButtonType.Normal)
        .width('100%')
        .height(44)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor(this.themeSelected)
        .borderRadius($r('app.float.radius_s'))
        .enabled(this.nodeSnapshot.pairingTicket.length > 0)
        .onClick(() => {
          this.copyPairingTicket()
        })
      TextArea({ text: this.pairingJoinTicket, placeholder: '粘贴另一台设备生成的配对票据' })
        .height(this.compactHeight() ? 72 : 88)
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .onChange((value: string) => {
          this.pairingJoinTicket = value
        })
      Button('加入配对')
        .type(ButtonType.Normal)
        .width('100%')
        .height(44)
        .fontColor(this.themeActionText)
        .backgroundColor(this.themeAccent)
        .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
        .borderRadius($r('app.float.radius_s'))
        .enabled(this.pairingJoinTicket.trim().length > 0 && this.nodeSnapshot.status === 'ready')
        .onClick(() => {
          this.joinPairing()
        })

      this.buildNoticePanel({
        title: '连接状态',
        status: '状态：' + this.nodeSnapshot.status,
        detail: this.nodeSnapshot.message + '\n设备名：' +
          (this.nodeSnapshot.deviceName.length > 0 ? this.nodeSnapshot.deviceName : '尚未读取') +
          '\nEndpoint：' + (this.nodeSnapshot.endpointId.length > 0 ? this.nodeSnapshot.endpointId : '尚未读取') +
          '\n网络：' + (this.nodeSnapshot.networkReady ? '已就绪' : '未就绪')
      })
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildNearbyDevices(): void {
    Text('附近设备')
      .fontSize($r('app.float.body_m'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
    if (this.nearbyDevices.length === 0) {
      this.buildPlainPanel({ title: '附近暂无设备', detail: '发现其他设备后，会显示在这里。' })
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
            .type(ButtonType.Normal)
            .height(44)
            .fontColor(this.themeActionText)
            .backgroundColor(this.themeAccent)
            .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.triggerPair(device.id)
            })
        }
        .padding(12)
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }, (device: NearbyDevice) => device.id)
    }
  }

  @Builder
  private buildHistorySection(): void {
    Column({ space: 0 }) {
      if (this.activeThreadId.length > 0) {
        if (this.currentThread().entries.length === 0) {
          Text('尚无往来').fontSize(14).fontColor($r('app.color.text_secondary')).padding({ top: 40, bottom: 40 })
        }
        ForEach(this.currentThread().entries, (entry: HistoryEntry) => {
          Column({ space: 8 }) {
            Text(this.historyTime(entry.timestamp) + ' · ' + entry.direction)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text(entry.title)
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text(entry.detail)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text(entry.status === 'completed' ? '已完成' : entry.status)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
          }
          .padding({ top: 20, bottom: 20 })
          .width('100%')
          .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
        }, (entry: HistoryEntry) => entry.id)
        if (this.activeThreadId !== 'ticket') {
          Button('发送文件')
            .type(ButtonType.Normal)
            .width('100%')
            .height(48)
            .margin({ top: 24 })
            .backgroundColor(this.themeAccent)
            .fontColor(this.themeActionText)
            .borderRadius(6)
            .enabled(this.deviceTargets().some((target: DeviceTarget) => target.id === this.activeThreadId && target.online))
            .onClick(() => {
              let target: DeviceTarget | undefined = this.deviceTargets().find((item: DeviceTarget) =>
                item.id === this.activeThreadId)
              if (target !== undefined) {
                this.beginDeviceTransfer(target)
              }
            })
        }
      } else {
        if (this.deviceThreads().length === 0) {
          Column({ space: 14 }) {
            Image($r('app.media.ux_transfer')).width(36).height(36).colorFilter(this.iconColor($r('app.color.text_secondary')))
            Text('还没有往来记录').fontSize(14).fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 60, bottom: 60 })
        }
        ForEach(this.deviceThreads(), (thread: DeviceThread) => {
          Button() {
            Row({ space: 14 }) {
              Image(thread.id === 'ticket' ? $r('app.media.ux_transfer') : this.deviceIcon(thread.deviceType))
                .width(42)
                .height(42)
                .padding(8)
                .colorFilter(this.iconColor($r('app.color.text_primary')))
                .backgroundColor($r('app.color.panel_surface'))
                .borderRadius(8)
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(thread.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(thread.entries.length > 0 ? this.historyTime(thread.entries[0].timestamp) : '')
                    .fontSize(10)
                    .fontColor($r('app.color.text_secondary'))
                }
                Text(thread.entries.length > 0 ? thread.entries[0].direction + ' · ' + thread.entries[0].title : '尚无往来')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(thread.id === 'ticket' ? thread.entries.length + ' 次传输' :
                  (thread.online ? '设备在线' : '设备离线') + ' · ' + thread.entries.length + ' 次往来')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
              .layoutWeight(1)
            }
            .padding({ top: 20, bottom: 20 })
          }
          .type(ButtonType.Normal)
          .width('100%')
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
          .onClick(() => {
            this.activeThreadId = thread.id
          })
        }, (thread: DeviceThread) => thread.id + ':' + thread.name + ':' + thread.online + ':' +
          thread.entries.length + ':' + (thread.entries[0]?.id ?? ''))
      }
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildSettingsSection(): void {
    Column({ space: 12 }) {
      if (this.nodeOperationStatus.length > 0) {
        this.buildPlainPanel({ title: '节点操作状态', detail: this.nodeOperationStatus })
      }
      Text('传输')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.buildToggleRow({ label: '后台恢复传输', enabled: this.settings.resumeInBackground,
        onToggleChanged: (value: boolean) => {
          this.updateResumeInBackground(value)
        }
      })
      Row() {
        Column({ space: 2 }) {
          Text('后台通知')
            .fontSize($r('app.float.body_m'))
            .fontColor($r('app.color.text_primary'))
          Text(this.notificationEnabled ? '已开启' : '未开启')
            .fontSize($r('app.float.caption'))
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('开启通知')
          .type(ButtonType.Normal)
          .height(44)
          .fontColor(this.themeActionText)
          .backgroundColor(this.themeAccent)
          .border({ width: this.themeActionText === '#000000' ? 1 : 0, color: '#000000' })
          .borderRadius($r('app.float.radius_s'))
          .enabled(!this.notificationEnabled)
          .onClick(() => {
            this.enableNotifications()
          })
      }
      .padding(12)
      .backgroundColor($r('app.color.glass_surface'))
      .border({ width: 1, color: $r('app.color.glass_edge') })
      .borderRadius($r('app.float.radius_s'))
      Text('设备与连接')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.buildSettingField({ label: '设备名', value: this.settings.deviceName, placeholder: '设备名',
        onValueChanged: (value: string) => {
          this.updateDeviceName(value)
        }
      })
      this.buildToggleRow({ label: '可发现性', enabled: this.settings.discoverable,
        onToggleChanged: (value: boolean) => {
          this.updateDiscoverable(value)
        }
      })
      this.buildSettingField({ label: '自定义 Relay URL', value: this.settings.defaultRelay,
        placeholder: '默认模式下留空', onValueChanged: (value: string) => {
          this.updateRelay(value)
        }
      })
      this.buildSettingField({ label: '自定义 Discovery URL', value: this.settings.defaultDiscovery,
        placeholder: '默认模式下留空', onValueChanged: (value: string) => {
          this.updateDiscovery(value)
        }
      })
      this.buildSettingField({ label: 'DNS Origin', value: this.settings.dnsOrigin,
        placeholder: '默认模式下留空', onValueChanged: (value: string) => {
          this.updateDnsOrigin(value)
        }
      })
      Text('外观')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.buildThemeColorSection()
      this.buildDisplayModeSection()
      this.buildPlainPanel({ title: '关于', detail: this.settings.about })
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private buildDisplayModeSection(): void {
    Column({ space: 12 }) {
      Text('显示模式')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Row({ space: 4 }) {
        ForEach(['跟随系统', '浅色', '深色'], (mode: string) => {
          Button(mode)
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(44)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(this.settings.theme === mode ? this.themeSelected : Color.Transparent)
            .animation({ duration: 180, curve: Curve.EaseOut })
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.updateDisplayMode(mode)
            })
        }, (mode: string) => mode)
      }
      .padding(4)
      .width('100%')
      .backgroundColor(this.themeTint)
      .borderRadius($r('app.float.radius_s'))
    }
    .padding(16)
    .width('100%')
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildThemeColorSection(): void {
    Column({ space: 10 }) {
      Text('主题色')
        .fontSize($r('app.float.body_m'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Row({ space: 10 }) {
        Row() {}
          .width(38)
          .height(38)
          .backgroundColor(this.themeAccent)
          .animation({ duration: 200, curve: Curve.EaseOut })
          .borderRadius(19)
        Text(this.themeAccent)
          .fontSize($r('app.float.body_s'))
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Button('选择颜色')
          .type(ButtonType.Normal)
          .height(44)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .borderRadius($r('app.float.radius_s'))
          .onClick(() => {
            this.openColorPicker()
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
    .shadow({ radius: 12, color: $r('app.color.glass_shadow'), offsetX: 0, offsetY: 3 })
  }

  @Builder
  private buildColorPickerModal(): void {
    Column() {
      Column({ space: 16 }) {
        Row() {
          Text('选择主题色')
            .fontSize($r('app.float.title_l'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.pickerPreview)
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')

        Row({ space: 9 }) {
          Stack({ alignContent: Alignment.TopStart }) {
            Row() {}
              .width('100%')
              .height(224)
              .linearGradient({
                angle: 90,
                colors: [
                  [0xFFFF0000, 0], [0xFFFFFF00, 1 / 6], [0xFF00FF00, 2 / 6],
                  [0xFF00FFFF, 3 / 6], [0xFF0000FF, 4 / 6], [0xFFFF00FF, 5 / 6], [0xFFFF0000, 1]
                ]
              })
            Row() {}
              .width('100%')
              .height(224)
              .linearGradient({ angle: 180, colors: [[Color.Transparent, 0], [Color.White, 1]] })
            Row() {}
              .width(16)
              .height(16)
              .backgroundColor(this.pickerBaseColor)
              .border({ width: 2, color: Color.White })
              .borderRadius(8)
              .position({
                x: Math.max(0, Math.min(this.pickerPlaneWidth - 16, this.pickerHue * this.pickerPlaneWidth - 8)),
                y: Math.max(0, Math.min(208, this.pickerWhiteness * 224 - 8))
              })
              .hitTestBehavior(HitTestMode.None)
          }
          .layoutWeight(1)
          .height(224)
          .borderRadius(6)
          .clip(true)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.pickerPlaneWidth = Number(newValue.width)
          })
          .onTouch((event: TouchEvent) => {
            this.updatePickerPlane(event)
          })
          Row() {}
            .width(36)
            .height(224)
            .backgroundColor(this.pickerPreview)
            .borderRadius(5)
          Stack({ alignContent: Alignment.TopStart }) {
            Row() {}
              .width(22)
              .height(224)
              .linearGradient({ angle: 180, colors: [[this.pickerBaseColor, 0], [Color.Black, 1]] })
            Row() {}
              .width(22)
              .height(8)
              .backgroundColor(Color.White)
              .border({ width: 1, color: Color.Black })
              .borderRadius(4)
              .position({ y: Math.max(0, Math.min(216, (1 - this.pickerBrightness) * 224 - 4)) })
              .hitTestBehavior(HitTestMode.None)
          }
          .width(22)
          .height(224)
          .borderRadius(6)
          .clip(true)
          .onTouch((event: TouchEvent) => {
            this.updatePickerBrightness(event)
          })
        }
        .width('100%')

        Row({ space: 8 }) {
          this.buildPickerRgbField({ label: 'R', value: this.redInput, onValueChanged: (value: string): void => {
            this.redInput = value
            this.previewRgbInput()
          } })
          this.buildPickerRgbField({ label: 'G', value: this.greenInput, onValueChanged: (value: string): void => {
            this.greenInput = value
            this.previewRgbInput()
          } })
          this.buildPickerRgbField({ label: 'B', value: this.blueInput, onValueChanged: (value: string): void => {
            this.blueInput = value
            this.previewRgbInput()
          } })
        }
        .width('100%')
        if (this.colorError.length > 0) {
          Text(this.colorError)
            .fontSize($r('app.float.body_s'))
            .fontColor($r('app.color.critical'))
            .width('100%')
            .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
        }
        Row({ space: 10 }) {
          Button('取消')
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(44)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.selected_surface'))
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.showColorPicker = false
            })
          Button('确定')
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(44)
            .fontColor(this.themeActionText)
            .backgroundColor(this.themeAccent)
            .borderRadius($r('app.float.radius_s'))
            .onClick(() => {
              this.saveRgbColor()
            })
        }
        .width('100%')
      }
      .padding(18)
      .width('90%')
      .backgroundColor($r('app.color.glass_surface'))
      .backgroundBlurStyle(BlurStyle.Thin)
      .border({ width: 1, color: $r('app.color.glass_edge') })
      .borderRadius(12)
      .shadow({ radius: 18, color: $r('app.color.glass_shadow'), offsetX: 0, offsetY: 5 })
      .translate({ y: this.pickerEditing ? -120 : 0 })
      .animation({ duration: 200, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
  }

  @Builder
  private buildPickerRgbField(field: PickerRgbField): void {
    Column({ space: 5 }) {
      Text(field.label)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
      TextInput({ text: field.value, placeholder: '0–255' })
        .type(InputType.Number)
        .maxLength(3)
        .height(44)
        .backgroundColor($r('app.color.panel_surface'))
        .border({ width: 1, color: $r('app.color.divider') })
        .borderRadius($r('app.float.radius_s'))
        .onFocus(() => {
          this.pickerEditing = true
        })
        .onBlur(() => {
          this.pickerEditing = false
        })
        .onChange(field.onValueChanged)
    }
    .layoutWeight(1)
  }

  @Builder
  private buildSettingField(field: SettingField): void {
    Column({ space: 6 }) {
      Text(field.label)
        .fontSize($r('app.float.body_s'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: field.value, placeholder: field.placeholder })
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .onChange((nextValue: string) => {
          field.onValueChanged(nextValue)
        })
    }
  }

  @Builder
  private buildToggleRow(toggle: ToggleRow): void {
    Row() {
      Column({ space: 2 }) {
        Text(toggle.label)
          .fontSize($r('app.float.body_m'))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(toggle.enabled ? '已启用' : '已关闭')
          .fontSize($r('app.float.caption'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: toggle.enabled })
        .selectedColor(this.themeAccent)
        .onChange((value: boolean) => {
          toggle.onToggleChanged(value)
        })
    }
    .padding(12)
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: 1, color: $r('app.color.glass_edge') })
    .borderRadius($r('app.float.radius_s'))
  }

  @Builder
  private buildContextPane(): void {
    Column({ space: 12 }) {
      this.buildPlainPanel({ title: '当前布局', detail: this.breakpoint === 'lg' ?
        '大屏三栏：导航 + 内容 + 上下文。' : '中屏双栏：导航 + 内容。' })
      this.buildPlainPanel({ title: '响应式规则', detail: '仅由窗口宽度断点控制：sm < 600，md 600-839，lg >= 840。' })
      this.buildPlainPanel({ title: '显示信息', detail: '宽 ' + this.displayState.width + ' · 高 ' +
        this.displayState.height + ' · 旋转 ' + this.displayState.rotation })
      this.buildPlainPanel({ title: '折叠状态', detail: this.displayState.isFoldable ?
        this.displayState.foldStatus : '当前设备不可折叠或未暴露折叠能力' })
      this.buildPlainPanel({ title: 'Iroh NodeService', detail: this.nodeSnapshot.status + ' · ' +
        (this.nodeSnapshot.networkReady ? '网络已就绪' : '网络未就绪') + '\n' + this.nodeSnapshot.message })
      this.buildPlainPanel({ title: '传输引擎', detail: this.engineSnapshot.message })
    }
    .padding(16)
    .width(240)
    .height('100%')
    .backgroundColor($r('app.color.glass_surface'))
    .border({ width: { left: 1 }, color: $r('app.color.glass_edge') })
  }

  build() {
    Column() {
      this.buildAppHeader()
      if (this.hasPendingTransferInvite && this.activeSection !== NavSection.RECEIVE) {
        Button(this.pendingTransferInvite.senderName + ' · 收到 ' + this.pendingTransferInvite.fileCount + ' 项')
          .type(ButtonType.Normal)
          .width('100%')
          .height(48)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .onClick(() => {
            this.openSecondary(NavSection.RECEIVE)
          })
      }
      if (this.hasPendingNearbyPairRequest && this.activeSection !== NavSection.PAIRING) {
        Button(this.pendingNearbyPairRequest.senderName + ' · 请求配对')
          .type(ButtonType.Normal)
          .width('100%')
          .height(48)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.themeSelected)
          .onClick(() => {
            this.openSecondary(NavSection.PAIRING)
          })
      }
      if (this.breakpoint === 'sm') {
        this.buildMainContent()
        this.buildTaskStrip()
        this.buildActionBar()
        this.buildBottomNav()
      } else if (this.breakpoint === 'md') {
        Row() {
          this.buildSidebar()
          Column() {
            this.buildMainContent()
            this.buildTaskStrip()
            this.buildActionBar()
          }
          .layoutWeight(1)
        }
        .layoutWeight(1)
      } else {
        Row() {
          this.buildSidebar()
          Column() {
            this.buildMainContent()
            this.buildTaskStrip()
            this.buildActionBar()
          }
          .layoutWeight(1)
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindContentCover(this.showColorPicker, this.buildColorPickerModal(), {
      modalTransition: ModalTransition.ALPHA,
      backgroundColor: Color.Transparent,
      onDisappear: () => {
        this.showColorPicker = false
        this.pickerEditing = false
      }
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.updateBreakpoint(Number(newValue.width), Number(newValue.height))
    })
  }
}