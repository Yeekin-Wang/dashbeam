import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'

export class PlatformContext {
  private uiContext: common.UIAbilityContext | null = null
  private windowStage: window.WindowStage | null = null

  setUIContext(context: common.UIAbilityContext): void {
    this.uiContext = context
  }

  getUIContext(): common.UIAbilityContext | null {
    return this.uiContext
  }

  clearUIContext(): void {
    this.uiContext = null
  }

  setWindowStage(stage: window.WindowStage): void {
    this.windowStage = stage
  }

  getWindowStage(): window.WindowStage | null {
    return this.windowStage
  }

  clearWindowStage(): void {
    this.windowStage = null
  }
}

export const platformContext: PlatformContext = new PlatformContext()