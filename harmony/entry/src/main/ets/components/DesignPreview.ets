@Component
export struct DesignPreview {
  onClose: () => void = (): void => {}

  build() {
    Column({ space: 20 }) {
      Button('返回工作台')
        .type(ButtonType.Normal)
        .height(44)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.glass_surface'))
        .border({ width: 1, color: $r('app.color.glass_edge') })
        .borderRadius($r('app.float.radius_s'))
        .onClick(() => this.onClose())
      Text('方案预览')
        .fontSize(28)
    }
    .width('100%')
    .height('100%')
  }
}