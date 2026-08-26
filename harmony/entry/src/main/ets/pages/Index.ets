import { AppShell } from '../components/AppShell'

@Entry
@Component
struct Index {
  build() {
    Column() {
      AppShell()
    }
    .width('100%')
    .height('100%')
  }
}