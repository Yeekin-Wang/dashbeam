/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { appLinkService } from '../services/AppLinkService';
import { engineService } from '../services/EngineService';
import { platformContext } from '../services/PlatformContext';
import { systemIntegrationService } from '../services/SystemIntegrationService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    platformContext.setUIContext(this.context);
    appLinkService.handleWant(want);
    systemIntegrationService.setTransferCancellationHandler((transferId: string): void => {
      engineService.cancel(transferId).then((cancelled: boolean): void => {
        if (!cancelled) {
          hilog.warn(DOMAIN, 'testTag', 'Native transfer was already unavailable after system cancellation.');
        }
      });
    });
    engineService.initializeNode().catch((error: Error): void => {
      hilog.error(DOMAIN, 'testTag', 'Failed to initialize node. Cause: %{public}s', error.message);
    });
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    appLinkService.handleWant(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
  }

  onDestroy(): void {
    systemIntegrationService.setForeground(false);
    platformContext.clearWindowStage();
    platformContext.clearUIContext();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    platformContext.setWindowStage(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      systemIntegrationService.requestNotificationAuthorization().catch((error: Error): void => {
        hilog.error(DOMAIN, 'testTag', 'Failed to request notification authorization. Cause: %{public}s', error.message);
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    platformContext.clearWindowStage();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    systemIntegrationService.setForeground(true);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    systemIntegrationService.setForeground(false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}