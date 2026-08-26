import { Want } from '@kit.AbilityKit'
import { url } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN: number = 0x0000
const TAG: string = 'AppLinkService'
const LINK_PROTOCOL: string = 'https:'
const LINK_HOST: string = 'app.dashbeam.net'
const RECEIVE_PATH: string = '/receive'

export type AppLinkListener = (ticket: string) => void

export class AppLinkService {
  private listeners: Array<AppLinkListener> = []
  private pendingTicket: string = ''

  subscribe(listener: AppLinkListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener)
    }
    if (this.pendingTicket.length === 0) {
      return
    }
    let ticket: string = this.pendingTicket
    this.pendingTicket = ''
    listener(ticket)
  }

  unsubscribe(listener: AppLinkListener): void {
    this.listeners = this.listeners.filter((item: AppLinkListener): boolean => item !== listener)
  }

  handleWant(want: Want): void {
    let uri: string | undefined = want.uri
    if (uri === undefined || uri.length === 0) {
      return
    }
    try {
      let parsed: url.URL = url.URL.parseURL(uri)
      if (parsed.protocol !== LINK_PROTOCOL || parsed.hostname !== LINK_HOST || parsed.pathname !== RECEIVE_PATH) {
        return
      }
      let ticketValue: string | null = parsed.params.get('ticket')
      let ticket: string = ticketValue === null ? '' : ticketValue.trim()
      if (ticket.length === 0) {
        return
      }
      this.deliver(ticket)
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to parse App Linking URI: %{public}s', (error as Error).message)
    }
  }

  private deliver(ticket: string): void {
    if (this.listeners.length === 0) {
      this.pendingTicket = ticket
      return
    }
    this.pendingTicket = ''
    this.listeners.forEach((listener: AppLinkListener): void => {
      listener(ticket)
    })
  }
}

export const appLinkService: AppLinkService = new AppLinkService()