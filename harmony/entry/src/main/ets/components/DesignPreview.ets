@Component
export struct DesignPreview {
  onClose: () => void = (): void => {}

  build() {
    Column({ space: 20 }) {
      Button('返回工作台')
        .onClick(() => this.onClose())
      Text('方案预览')
        .fontSize(28)
    }
    .width('100%')
    .height('100%')
  }
}