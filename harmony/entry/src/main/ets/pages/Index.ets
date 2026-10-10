import { AppShell, AppShellNavigation } from '../components/AppShell'

@Entry
@Component
struct Index {
  private navigation: AppShellNavigation = new AppShellNavigation()

  onBackPress(): boolean {
    return this.navigation.onBack()
  }

  build() {
    Column() {
      AppShell({ navigation: this.navigation })
    }
    .width('100%')
    .height('100%')
  }
}