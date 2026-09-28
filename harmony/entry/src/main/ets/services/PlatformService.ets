import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit'
import { fileIo, picker, fileShare } from '@kit.CoreFileKit'
import { display } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  AppSettings,
  DisplayState,
  FilePreviewMetadata,
  HistoryEntry,
  TransferMetadata,
  TransferItem
} from '../models/AppModels'
import { nativeBridge } from './NativeBridge'
import { platformContext } from './PlatformContext'

const STORE_NAME: string = 'dashbeam_harmony'
const SETTINGS_KEY: string = 'app_settings'
const HISTORY_KEY: string = 'transfer_history'
const PERSISTED_URIS_KEY: string = 'persisted_uris'

interface StoredSettings {
  deviceName: string
  theme: string
  accentColor?: string
  discoverable: boolean
  defaultRelay: string
  defaultDiscovery: string
  dnsOrigin: string
  resumeInBackground: boolean
  about: string
}

interface StoredHistoryEntry {
  id: string
  direction: string
  title: string
  detail: string
  timestamp: string
  status: string
}

type DisplayListener = (state: DisplayState) => void

export class PlatformService {
  private store: preferences.Preferences | null = null
  private displayListeners: Array<DisplayListener> = []
  private foldStatusCallback: Callback<display.FoldStatus> | null = null

  private ensureStore(): preferences.Preferences | null {
    if (this.store !== null) {
      return this.store
    }
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      return null
    }
    let options: preferences.Options = {
      name: STORE_NAME,
      storageType: preferences.StorageType.GSKV
    }
    try {
      this.store = preferences.getPreferencesSync(context, options)
    } catch (_error) {
      return null
    }
    return this.store
  }

  private readStringValue(key: string, fallback: string): string {
    let store: preferences.Preferences | null = this.ensureStore()
    if (store === null) {
      return fallback
    }
    let value: preferences.ValueType
    try {
      value = store.getSync(key, fallback)
    } catch (_error) {
      return fallback
    }
    if (typeof value === 'string') {
      return value
    }
    return fallback
  }

  private writeStringValue(key: string, value: string): void {
    let store: preferences.Preferences | null = this.ensureStore()
    if (store === null) {
      return
    }
    try {
      store.putSync(key, value)
    } catch (_error) {
      return
    }
  }

  private createPolicyInfo(uri: string, operationMode: number): fileShare.PolicyInfo {
    let policyInfo: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: operationMode
    }
    return policyInfo
  }

  private parseSettings(raw: string): AppSettings {
    let next: AppSettings = new AppSettings()
    if (raw.length === 0) {
      return next
    }
    try {
      let stored: StoredSettings = JSON.parse(raw) as StoredSettings
      next.deviceName = stored.deviceName ?? next.deviceName
      next.theme = stored.theme ?? next.theme
      if (typeof stored.accentColor === 'string' && /^#[0-9a-fA-F]{6}$/.test(stored.accentColor)) {
        next.accentColor = stored.accentColor.toUpperCase()
      }
      next.discoverable = stored.discoverable ?? next.discoverable
      next.defaultRelay = stored.defaultRelay ?? next.defaultRelay
      next.defaultDiscovery = stored.defaultDiscovery ?? next.defaultDiscovery
      next.dnsOrigin = stored.dnsOrigin ?? next.dnsOrigin
      next.resumeInBackground = stored.resumeInBackground ?? next.resumeInBackground
      next.about = stored.about ?? next.about
    } catch (_error) {
      return next
    }
    return next
  }

  private serializeSettings(settings: AppSettings): string {
    let stored: StoredSettings = {
      deviceName: settings.deviceName,
      theme: settings.theme,
      accentColor: settings.accentColor,
      discoverable: settings.discoverable,
      defaultRelay: settings.defaultRelay,
      defaultDiscovery: settings.defaultDiscovery,
      dnsOrigin: settings.dnsOrigin,
      resumeInBackground: settings.resumeInBackground,
      about: settings.about
    }
    return JSON.stringify(stored)
  }

  private parseHistory(raw: string): Array<HistoryEntry> {
    if (raw.length === 0) {
      return []
    }
    let items: Array<HistoryEntry> = []
    try {
      let stored: Array<StoredHistoryEntry> = JSON.parse(raw) as Array<StoredHistoryEntry>
      stored.forEach((entry: StoredHistoryEntry) => {
        let item: HistoryEntry = new HistoryEntry()
        item.id = entry.id
        item.direction = entry.direction
        item.title = entry.title
        item.detail = entry.detail
        item.timestamp = entry.timestamp
        item.status = entry.status
        items.push(item)
      })
    } catch (_error) {
      return []
    }
    return items
  }

  private serializeHistory(items: Array<HistoryEntry>): string {
    return JSON.stringify(items)
  }

  private readPersistedUris(): Array<string> {
    let raw: string = this.readStringValue(PERSISTED_URIS_KEY, '[]')
    try {
      let values: Array<string> = JSON.parse(raw) as Array<string>
      return values
    } catch (_error) {
      return []
    }
  }

  private writePersistedUris(uris: Array<string>): void {
    this.writeStringValue(PERSISTED_URIS_KEY, JSON.stringify(uris))
  }

  private makeTransferItem(uri: string, kind: string): TransferItem {
    let item: TransferItem = new TransferItem()
    item.id = uri
    item.uri = uri
    item.kind = kind
    item.name = this.extractNameFromUri(uri)
    item.sizeLabel = ''
    return item
  }

  private extractNameFromUri(uri: string): string {
    let lastSlashIndex: number = uri.lastIndexOf('/')
    if (lastSlashIndex < 0 || lastSlashIndex >= uri.length - 1) {
      return uri
    }
    let leaf: string = uri.substring(lastSlashIndex + 1)
    try {
      return decodeURIComponent(leaf)
    } catch (_error) {
      return leaf
    }
  }

  private safeLeafName(value: string, fallback: string): string {
    let name: string = value.replace(/[\\/]/g, '_').trim()
    if (name.length === 0 || name === '.' || name === '..') {
      return fallback
    }
    return name
  }

  private ensureDirectory(path: string): void {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path, true)
    }
  }

  private removeTree(path: string): void {
    if (!fileIo.accessSync(path)) {
      return
    }
    if (!fileIo.statSync(path).isDirectory()) {
      fileIo.unlinkSync(path)
      return
    }
    fileIo.listFileSync(path).forEach((name: string) => {
      this.removeTree(path + '/' + name)
    })
    fileIo.rmdirSync(path)
  }

  private resetDirectory(path: string): void {
    this.removeTree(path)
    this.ensureDirectory(path)
  }

  private uniqueChildPath(parent: string, requestedName: string, fallback: string): string {
    let name: string = this.safeLeafName(requestedName, fallback)
    let candidate: string = parent + '/' + name
    let suffix: number = 2
    while (fileIo.accessSync(candidate)) {
      candidate = parent + '/' + name + ' (' + suffix + ')'
      suffix += 1
    }
    return candidate
  }

  private async copyUriFileToPath(sourceUri: string, destinationPath: string): Promise<void> {
    let source: fileIo.File = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY)
    let destination: fileIo.File
    try {
      destination = fileIo.openSync(
        destinationPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      )
    } catch (_error) {
      fileIo.closeSync(source)
      throw new Error('无法创建发送暂存文件。')
    }
    try {
      await fileIo.copyFile(source.fd, destination.fd)
    } finally {
      fileIo.closeSync(source)
      fileIo.closeSync(destination)
    }
  }

  private async copyPathFileToUri(sourcePath: string, destinationUri: string): Promise<void> {
    let source: fileIo.File = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY)
    let destination: fileIo.File
    try {
      destination = fileIo.openSync(
        destinationUri,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      )
    } catch (_error) {
      fileIo.closeSync(source)
      throw new Error('无法打开用户选择的保存目标。')
    }
    try {
      await fileIo.copyFile(source.fd, destination.fd)
    } finally {
      fileIo.closeSync(source)
      fileIo.closeSync(destination)
    }
  }

  private async copyDirectoryTree(sourcePath: string, destinationPath: string): Promise<void> {
    this.ensureDirectory(destinationPath)
    let names: Array<string> = await fileIo.listFile(sourcePath)
    for (let index: number = 0; index < names.length; index += 1) {
      let name: string = names[index]
      let sourceChild: string = sourcePath + '/' + name
      let destinationChild: string = destinationPath + '/' + name
      if ((await fileIo.stat(sourceChild)).isDirectory()) {
        await this.copyDirectoryTree(sourceChild, destinationChild)
      } else {
        await fileIo.copyFile(sourceChild, destinationChild)
      }
    }
  }

  private async collectFiles(path: string, result: Array<string>): Promise<void> {
    let names: Array<string> = await fileIo.listFile(path)
    for (let index: number = 0; index < names.length; index += 1) {
      let child: string = path + '/' + names[index]
      if ((await fileIo.stat(child)).isDirectory()) {
        await this.collectFiles(child, result)
      } else {
        result.push(child)
      }
    }
  }

  private async calculatePathSize(path: string): Promise<number> {
    let pathStat: fileIo.Stat = await fileIo.stat(path)
    if (!pathStat.isDirectory()) {
      return pathStat.size
    }
    let totalSize: number = 0
    let names: Array<string> = await fileIo.listFile(path)
    for (let index: number = 0; index < names.length; index += 1) {
      totalSize += await this.calculatePathSize(path + '/' + names[index])
    }
    return totalSize
  }

  private notifyDisplayListeners(): void {
    let state: DisplayState = this.getDisplayState()
    this.displayListeners.forEach((listener: DisplayListener) => {
      listener(state)
    })
  }

  private persistPermissionSupported(): boolean {
    return canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')
  }

  isFolderSelectionSupported(): boolean {
    return canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')
  }

  async activatePersistedUris(): Promise<void> {
    if (!this.persistPermissionSupported()) {
      return
    }
    let uris: Array<string> = this.readPersistedUris()
    if (uris.length === 0) {
      return
    }
    let policies: Array<fileShare.PolicyInfo> = uris.map((uri: string) => {
      return this.createPolicyInfo(uri, fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE)
    })
    try {
      await fileShare.activatePermission(policies)
    } catch (_error) {
      return
    }
  }

  async persistUris(uris: Array<string>, operationMode: number): Promise<void> {
    if (!this.persistPermissionSupported() || uris.length === 0) {
      return
    }
    let policies: Array<fileShare.PolicyInfo> = uris.map((uri: string) => {
      return this.createPolicyInfo(uri, operationMode)
    })
    try {
      await fileShare.persistPermission(policies)
      let nextUris: Array<string> = [...this.readPersistedUris()]
      uris.forEach((uri: string) => {
        if (!nextUris.includes(uri)) {
          nextUris.push(uri)
        }
      })
      this.writePersistedUris(nextUris)
    } catch (_error) {
      return
    }
  }

  async loadSettings(): Promise<AppSettings> {
    await this.activatePersistedUris()
    return this.parseSettings(this.readStringValue(SETTINGS_KEY, ''))
  }

  async saveSettings(settings: AppSettings): Promise<AppSettings> {
    this.writeStringValue(SETTINGS_KEY, this.serializeSettings(settings))
    return settings.clone()
  }

  applyDisplayMode(theme: string): void {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      throw new Error('UIAbilityContext 不可用，无法切换显示模式。')
    }
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
    if (theme === '浅色') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
    } else if (theme === '深色') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    }
    context.getApplicationContext().setColorMode(colorMode)
    this.updateSystemBarAppearance(theme === '跟随系统' ? context.config.colorMode : colorMode)
  }

  updateSystemBarAppearance(colorMode?: ConfigurationConstant.ColorMode): void {
    let stage = platformContext.getWindowStage()
    if (stage === null) {
      return
    }
    let contentColor: string = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
      '#F2F6F4' : '#21342C'
    stage.getMainWindowSync().setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    }).catch((error: Error): void => {
      hilog.error(0x0000, 'DashBeam', 'Failed to update system bars. Cause: %{public}s', error.message)
    })
  }

  async loadHistory(): Promise<Array<HistoryEntry>> {
    return this.parseHistory(this.readStringValue(HISTORY_KEY, '[]'))
  }

  async saveHistory(items: Array<HistoryEntry>): Promise<Array<HistoryEntry>> {
    this.writeStringValue(HISTORY_KEY, this.serializeHistory(items))
    return [...items]
  }

  prepareNodeDataDirectory(): string {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      throw new Error('UIAbilityContext 不可用，无法创建设备节点目录。')
    }
    let directory: string = context.filesDir + '/dashbeam/node'
    this.ensureDirectory(directory)
    return directory
  }

  getNodeDeviceType(): string {
    let systemType: string = deviceInfo.deviceType.toLowerCase()
    if (systemType === 'phone' || systemType === 'tablet' || systemType === '2in1' ||
      systemType === 'foldable' || systemType === 'widefold' || systemType === 'triplefold') {
      if (systemType === 'phone') {
        try {
          return display.isFoldable() ? 'foldable' : 'phone'
        } catch (_error) {
          return 'phone'
        }
      }
      return systemType
    }
    try {
      return display.isFoldable() ? 'foldable' : 'unknown'
    } catch (_error) {
      return 'unknown'
    }
  }

  async selectFiles(): Promise<Array<TransferItem>> {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      return []
    }
    let documentSelectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
    documentSelectOptions.maxSelectNumber = 100
    documentSelectOptions.selectMode = picker.DocumentSelectMode.FILE
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
    let resultUris: Array<string> = await documentPicker.select(documentSelectOptions)
    await this.persistUris(resultUris, fileShare.OperationMode.READ_MODE)
    return resultUris.map((uri: string) => this.makeTransferItem(uri, '文件'))
  }

  async selectFolder(): Promise<Array<TransferItem>> {
    if (!this.isFolderSelectionSupported()) {
      return Promise.reject(new Error('当前设备不支持 FolderSelection system capability，无法选择文件夹。'))
    }
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      return []
    }
    let documentSelectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
    documentSelectOptions.maxSelectNumber = 1
    documentSelectOptions.selectMode = picker.DocumentSelectMode.FOLDER
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
    let resultUris: Array<string> = await documentPicker.select(documentSelectOptions)
    await this.persistUris(resultUris, fileShare.OperationMode.READ_MODE)
    return resultUris.map((uri: string) => this.makeTransferItem(uri, '文件夹'))
  }

  async chooseSaveTarget(suggestedName: string): Promise<string> {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      return ''
    }
    let documentSaveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions()
    documentSaveOptions.newFileNames = [suggestedName]
    documentSaveOptions.autoCreateEmptyFile = false
    let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
    let resultUris: Array<string> = await documentPicker.save(documentSaveOptions)
    await this.persistUris(resultUris, fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE)
    if (resultUris.length === 0) {
      return ''
    }
    return resultUris[0]
  }

  async stageShareItems(sessionId: string, items: Array<TransferItem>): Promise<Array<string>> {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      return Promise.reject(new Error('UIAbilityContext 不可用，无法暂存发送内容。'))
    }
    let sessionDirectory: string = context.cacheDir + '/dashbeam/share/' + this.safeLeafName(sessionId, 'session')
    this.resetDirectory(sessionDirectory)

    let stagedPaths: Array<string> = []
    try {
      for (let index: number = 0; index < items.length; index += 1) {
        let item: TransferItem = items[index]
        let destinationPath: string = this.uniqueChildPath(
          sessionDirectory,
          item.name,
          'item-' + (index + 1)
        )
        if (item.kind === '文件夹') {
          let sourcePath: string = nativeBridge.resolveFileUri(item.uri)
          if (!fileIo.statSync(sourcePath).isDirectory()) {
            throw new Error('选择的目录 URI 未解析为目录: ' + item.name)
          }
          await this.copyDirectoryTree(sourcePath, destinationPath)
        } else {
          await this.copyUriFileToPath(item.uri, destinationPath)
        }
        stagedPaths.push(destinationPath)
      }
    } catch (error) {
      this.removeTree(sessionDirectory)
      throw new Error((error as Error).message)
    }
    return stagedPaths
  }

  async buildTransferMetadata(stagedPaths: Array<string>): Promise<TransferMetadata> {
    let metadata: TransferMetadata = new TransferMetadata()
    metadata.itemCount = stagedPaths.length
    for (let index: number = 0; index < stagedPaths.length; index += 1) {
      let path: string = stagedPaths[index]
      let item: FilePreviewMetadata = new FilePreviewMetadata()
      item.fileName = this.extractNameFromUri(path)
      item.size = await this.calculatePathSize(path)
      metadata.items.push(item)
      metadata.size += item.size
    }
    if (metadata.items.length === 1) {
      metadata.fileName = metadata.items[0].fileName
    } else if (metadata.items.length > 1) {
      metadata.fileName = metadata.items[0].fileName + ' 等 ' + metadata.items.length + ' 项'
    }
    return metadata
  }

  prepareReceiveOutput(sessionId: string): string {
    let context: common.UIAbilityContext | null = platformContext.getUIContext()
    if (context === null) {
      throw new Error('UIAbilityContext 不可用，无法创建接收目录。')
    }
    let outputDirectory: string = context.filesDir + '/dashbeam/receive/' + this.safeLeafName(sessionId, 'session')
    this.resetDirectory(outputDirectory)
    return outputDirectory
  }

  async exportReceivedFiles(outputDirectory: string, targetUri: string): Promise<number> {
    let files: Array<string> = []
    await this.collectFiles(outputDirectory, files)
    if (files.length === 0) {
      return Promise.reject(new Error('接收完成，但沙箱输出目录中没有文件。'))
    }

    let targetPath: string = nativeBridge.resolveFileUri(targetUri)
    if (fileIo.accessSync(targetPath) && fileIo.statSync(targetPath).isDirectory()) {
      for (let index: number = 0; index < files.length; index += 1) {
        let relativePath: string = files[index].substring(outputDirectory.length + 1)
        let destinationPath: string = targetPath + '/' + relativePath
        let separatorIndex: number = destinationPath.lastIndexOf('/')
        if (separatorIndex > 0) {
          this.ensureDirectory(destinationPath.substring(0, separatorIndex))
        }
        await fileIo.copyFile(files[index], destinationPath)
      }
      return files.length
    }

    if (files.length !== 1) {
      return Promise.reject(new Error('收到多个文件，但当前保存目标是单个文件。请选择文件夹目标后重试。'))
    }
    await this.copyPathFileToUri(files[0], targetUri)
    return 1
  }

  cleanupTransferDirectory(path: string): void {
    try {
      this.removeTree(path)
    } catch (_error) {
      return
    }
  }

  async copyTicket(ticket: string): Promise<boolean> {
    if (ticket.length === 0) {
      return false
    }
    try {
      let pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, ticket)
      let systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      await systemPasteboard.setData(pasteData)
    } catch (_error) {
      return false
    }
    return true
  }

  getDisplayState(): DisplayState {
    let state: DisplayState = new DisplayState()
    try {
      let defaultDisplay: display.Display = display.getDefaultDisplaySync()
      state.width = defaultDisplay.width
      state.height = defaultDisplay.height
      state.rotation = defaultDisplay.rotation
      if (display.isFoldable()) {
        state.isFoldable = true
        state.foldStatus = this.foldStatusLabel(display.getFoldStatus())
      }
    } catch (_error) {
      return state
    }
    return state
  }

  private foldStatusLabel(status: display.FoldStatus): string {
    if (status === display.FoldStatus.FOLD_STATUS_EXPANDED) {
      return '展开'
    }
    if (status === display.FoldStatus.FOLD_STATUS_FOLDED) {
      return '折叠'
    }
    if (status === display.FoldStatus.FOLD_STATUS_HALF_FOLDED) {
      return '半折叠'
    }
    return '未知'
  }

  subscribeDisplay(listener: DisplayListener): void {
    this.displayListeners.push(listener)
    listener(this.getDisplayState())
    try {
      if (this.foldStatusCallback === null && display.isFoldable()) {
        this.foldStatusCallback = (_status: display.FoldStatus): void => {
          this.notifyDisplayListeners()
        }
        display.on('foldStatusChange', this.foldStatusCallback)
      }
    } catch (_error) {
      return
    }
  }

  unsubscribeDisplay(listener: DisplayListener): void {
    this.displayListeners = this.displayListeners.filter((entry: DisplayListener) => entry !== listener)
    if (this.displayListeners.length === 0 && this.foldStatusCallback !== null) {
      display.off('foldStatusChange', this.foldStatusCallback)
      this.foldStatusCallback = null
    }
  }

}

export const platformService: PlatformService = new PlatformService()