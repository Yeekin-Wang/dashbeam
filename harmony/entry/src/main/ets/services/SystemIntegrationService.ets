import { WantAgent, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { IncomingTransferInvite, NearbyPairRequest, TransferProgress } from '../models/AppModels'
import { platformContext } from './PlatformContext'
import { platformService } from './PlatformService'

const DOMAIN: number = 0x0000
const TAG: string = 'SystemIntegration'
const BUNDLE_NAME: string = 'com.dashbeam.harmony'
const ENTRY_ABILITY: string = 'EntryAbility'
const LIVE_VIEW_TYPE_CODE: number = 8
const PROGRESS_MAX: number = 100
const PROGRESS_UPDATE_INTERVAL_MS: number = 1000
const INBOUND_NOTIFICATION_BASE_ID: number = 1500000000

export type TransferCancellationHandler = (transferId: string) => void

class TransferBackgroundTask {
  transferId: string
  direction: string
  progress: TransferProgress
  notificationId: number = -1
  continuousTaskId: number = -1
  stopRequested: boolean = false
  lastQueuedAt: number = 0
  pending: Promise<void> = Promise.resolve()

  constructor(transferId: string, direction: string, progress: TransferProgress) {
    this.transferId = transferId
    this.direction = direction
    this.progress = progress
  }
}

export class SystemIntegrationService {
  private transfers: Map<string, TransferBackgroundTask> = new Map<string, TransferBackgroundTask>()
  private transferCancellationHandler: TransferCancellationHandler | null = null
  private continuousTaskCancelRegistered: boolean = false
  private reconciliation: Promise<void> = Promise.resolve()
  private reconciliationStarted: boolean = false
  private requestSequence: number = 0
  private inboundNotificationSequence: number = 0
  private inboundNotificationIds: Set<number> = new Set<number>()
  private notificationAuthorizationRequested: boolean = false
  private foreground: boolean = true

  private readonly continuousTaskCancelListener =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      let task: TransferBackgroundTask | undefined = Array.from(this.transfers.values()).find(
        (candidate: TransferBackgroundTask): boolean => candidate.continuousTaskId === info.id
      )
      if (task === undefined) {
        return
      }
      let shouldCancelNative: boolean = !task.stopRequested
      task.stopRequested = true
      if (this.transfers.get(task.transferId) === task) {
        this.transfers.delete(task.transferId)
      }
      hilog.info(DOMAIN, TAG, 'Continuous task %{public}d cancelled with reason %{public}d', info.id, info.reason)
      if (shouldCancelNative && this.transferCancellationHandler !== null) {
        this.transferCancellationHandler(task.transferId)
      }
    }

  setTransferCancellationHandler(handler: TransferCancellationHandler): void {
    this.transferCancellationHandler = handler
    if (!this.continuousTaskCancelRegistered) {
      try {
        backgroundTaskManager.on('continuousTaskCancel', this.continuousTaskCancelListener)
        this.continuousTaskCancelRegistered = true
      } catch (error) {
        this.logError('Failed to register continuous task cancellation listener', error as Error)
      }
    }
    if (!this.reconciliationStarted) {
      this.reconciliationStarted = true
      this.reconciliation = this.reconcileContinuousTasks().catch((error: Error): void => {
        this.logError('Failed to reconcile continuous tasks', error)
      })
    }
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground
    if (foreground) {
      let notificationIds: Array<number> = Array.from(this.inboundNotificationIds)
      this.inboundNotificationIds.clear()
      notificationIds.forEach((notificationId: number): void => {
        this.cancelInboundNotification(notificationId)
      })
    }
  }

  isForeground(): boolean {
    return this.foreground
  }

  async requestNotificationAuthorization(): Promise<void> {
    if (this.notificationAuthorizationRequested) {
      return
    }
    let context = platformContext.getUIContext()
    if (context === null) {
      return
    }
    this.notificationAuthorizationRequested = true
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        await notificationManager.requestEnableNotification(context)
      }
    } catch (error) {
      this.logError('Notification authorization failed', error as Error)
    }
  }

  notifyNearbyPairRequest(request: NearbyPairRequest): void {
    let sender: string = request.senderName.length > 0 ? request.senderName : '附近设备'
    this.publishInboundNotification('配对请求', sender + ' 请求与此设备配对').catch((error: Error): void => {
      this.logError('Failed to publish pairing request notification', error)
    })
  }

  notifyTransferInvite(invite: IncomingTransferInvite): void {
    let sender: string = invite.senderName.length > 0 ? invite.senderName : '附近设备'
    let detail: string = sender + ' 想发送 ' + invite.fileCount + ' 项，共 ' + this.formatBytes(invite.totalSize)
    this.publishInboundNotification('收到传输邀请', detail).catch((error: Error): void => {
      this.logError('Failed to publish transfer invite notification', error)
    })
  }

  startTransfer(transferId: string, direction: string, progress: TransferProgress): void {
    let current: TransferBackgroundTask | undefined = this.transfers.get(transferId)
    if (current !== undefined) {
      this.updateTransfer(progress)
      return
    }
    let task: TransferBackgroundTask = new TransferBackgroundTask(
      transferId,
      direction,
      this.copyProgress(progress)
    )
    this.transfers.set(transferId, task)
    task.pending = this.reconciliation.then(async (): Promise<void> => {
      await this.startBackgroundTask(task)
    }).catch((error: Error): void => {
      this.logError('Failed to start transfer background task ' + transferId, error)
      if (this.transfers.get(transferId) === task) {
        this.transfers.delete(transferId)
      }
    })
  }

  updateTransfer(progress: TransferProgress): void {
    let candidate: TransferBackgroundTask | undefined = this.transfers.get(progress.transferId)
    if (candidate === undefined) {
      return
    }
    let task: TransferBackgroundTask = candidate
    if (task.stopRequested) {
      return
    }
    task.progress = this.copyProgress(progress)
    if (task.notificationId < 0) {
      return
    }
    let now: number = Date.now()
    if (now - task.lastQueuedAt < PROGRESS_UPDATE_INTERVAL_MS && progress.progressRatio < 1) {
      return
    }
    task.lastQueuedAt = now
    task.pending = task.pending.then(async (): Promise<void> => {
      if (!task.stopRequested) {
        await this.publishTransferProgress(task)
      }
    }).catch((error: Error): void => {
      this.logError('Failed to update transfer notification ' + progress.transferId, error)
    })
  }

  stopTransfer(transferId: string): void {
    let candidate: TransferBackgroundTask | undefined = this.transfers.get(transferId)
    if (candidate === undefined) {
      return
    }
    let task: TransferBackgroundTask = candidate
    if (task.stopRequested) {
      return
    }
    task.stopRequested = true
    task.pending = task.pending.then(async (): Promise<void> => {
      await this.stopBackgroundTask(task)
      if (this.transfers.get(transferId) === task) {
        this.transfers.delete(transferId)
      }
    }).catch((error: Error): void => {
      this.logError('Failed to stop transfer background task ' + transferId, error)
    })
  }

  private async startBackgroundTask(task: TransferBackgroundTask): Promise<void> {
    let settings = await platformService.loadSettings()
    if (!settings.resumeInBackground) {
      this.transfers.delete(task.transferId)
      return
    }
    let context = platformContext.getUIContext()
    if (context === null) {
      throw new Error('UIAbility context is unavailable.')
    }
    let taskRequest: backgroundTaskManager.ContinuousTaskRequest =
      new backgroundTaskManager.ContinuousTaskRequest()
    taskRequest.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER]
    taskRequest.backgroundTaskSubmodes = [
      backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION
    ]
    taskRequest.wantAgent = await this.createEntryWantAgent()
    taskRequest.combinedTaskNotification = false
    let result: backgroundTaskManager.ContinuousTaskNotification =
      await backgroundTaskManager.startBackgroundRunning(context, taskRequest)
    task.notificationId = result.notificationId
    task.continuousTaskId = result.continuousTaskId ??
      await this.findContinuousTaskId(result.notificationId)
    if (task.continuousTaskId < 0) {
      throw new Error('The system did not return a manageable continuous task ID.')
    }
    if (!task.stopRequested) {
      task.lastQueuedAt = Date.now()
      await this.publishTransferProgress(task)
    }
  }

  private async stopBackgroundTask(task: TransferBackgroundTask): Promise<void> {
    let context = platformContext.getUIContext()
    if (context === null) {
      throw new Error('UIAbility context is unavailable.')
    }
    if (task.continuousTaskId < 0 && task.notificationId >= 0) {
      task.continuousTaskId = await this.findContinuousTaskId(task.notificationId)
    }
    if (task.continuousTaskId < 0) {
      throw new Error('Continuous task ID is unavailable; refusing to stop unrelated tasks.')
    }
    await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId)
  }

  private async reconcileContinuousTasks(): Promise<void> {
    let context = platformContext.getUIContext()
    if (context === null) {
      return
    }
    let trackedIds: Set<number> = new Set<number>()
    this.transfers.forEach((task: TransferBackgroundTask): void => {
      if (task.continuousTaskId >= 0) {
        trackedIds.add(task.continuousTaskId)
      }
    })
    let systemTasks: Array<backgroundTaskManager.ContinuousTaskInfo> =
      await backgroundTaskManager.getAllContinuousTasks(context, true)
    let orphanedTasks: Array<backgroundTaskManager.ContinuousTaskInfo> = systemTasks.filter(
      (task: backgroundTaskManager.ContinuousTaskInfo): boolean => {
        let belongsToEntry: boolean = task.abilityName === ENTRY_ABILITY &&
          (task.bundleName === undefined || task.bundleName === BUNDLE_NAME)
        return belongsToEntry && !trackedIds.has(task.continuousTaskId)
      }
    )
    for (let task of orphanedTasks) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId)
        hilog.info(DOMAIN, TAG, 'Removed orphaned continuous task %{public}d', task.continuousTaskId)
      } catch (error) {
        this.logError('Failed to remove orphaned continuous task ' + task.continuousTaskId, error as Error)
      }
    }
  }

  private async publishTransferProgress(task: TransferBackgroundTask): Promise<void> {
    let percentage: number = Math.round(Math.max(0, Math.min(task.progress.progressRatio, 1)) * PROGRESS_MAX)
    let title: string = task.progress.title.length > 0 ? task.progress.title :
      (task.direction === 'send' ? '正在发送' : '正在接收')
    let detail: string = task.progress.bytesLabel.length > 0 ? task.progress.bytesLabel : task.progress.detail
    if (detail.length === 0) {
      detail = task.direction === 'send' ? '正在准备发送内容' : '正在准备接收内容'
    }
    let template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title: title,
        fileName: detail,
        progressValue: percentage
      }
    }
    let request: notificationManager.NotificationRequest = {
      id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      updateOnly: true,
      isAlertOnce: true,
      template: template,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: LIVE_VIEW_TYPE_CODE,
          title: title,
          text: detail,
          progress: {
            maxValue: PROGRESS_MAX,
            currentValue: percentage,
            isPercentage: true
          }
        }
      }
    }
    await notificationManager.publish(request)
  }

  private async createEntryWantAgent(): Promise<WantAgent> {
    this.requestSequence += 1
    let info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: BUNDLE_NAME,
          abilityName: ENTRY_ABILITY
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: this.requestSequence,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return wantAgent.getWantAgent(info)
  }

  private async publishInboundNotification(title: string, text: string): Promise<void> {
    if (this.foreground || !await notificationManager.isNotificationEnabled()) {
      return
    }
    let notificationId: number = this.nextInboundNotificationId()
    let entryWantAgent: WantAgent = await this.createEntryWantAgent()
    if (this.foreground) {
      return
    }
    let request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      tapDismissed: true,
      showDeliveryTime: true,
      wantAgent: entryWantAgent,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    }
    await notificationManager.publish(request)
    if (this.foreground) {
      await this.cancelInboundNotification(notificationId)
      return
    }
    this.inboundNotificationIds.add(notificationId)
  }

  private async cancelInboundNotification(notificationId: number): Promise<void> {
    try {
      await notificationManager.cancel(notificationId)
    } catch (error) {
      this.logError('Failed to cancel inbound notification ' + notificationId, error as Error)
    }
  }

  private nextInboundNotificationId(): number {
    this.inboundNotificationSequence += 1
    return INBOUND_NOTIFICATION_BASE_ID + this.inboundNotificationSequence
  }

  private async findContinuousTaskId(notificationId: number): Promise<number> {
    let context = platformContext.getUIContext()
    if (context === null) {
      return -1
    }
    let tasks: Array<backgroundTaskManager.ContinuousTaskInfo> =
      await backgroundTaskManager.getAllContinuousTasks(context, true)
    let match: backgroundTaskManager.ContinuousTaskInfo | undefined = tasks.find(
      (task: backgroundTaskManager.ContinuousTaskInfo): boolean => task.notificationId === notificationId
    )
    return match === undefined ? -1 : match.continuousTaskId
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

  private logError(message: string, error: Error): void {
    hilog.error(DOMAIN, TAG, '%{public}s: %{public}s', message, error.message)
  }
}

export const systemIntegrationService: SystemIntegrationService = new SystemIntegrationService()