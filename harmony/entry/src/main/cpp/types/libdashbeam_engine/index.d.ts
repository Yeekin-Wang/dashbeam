export type DashbeamEventCallback = (eventJson: string) => void

export interface DashbeamEngineModule {
	abiVersion(): number
	bridgeStatus(): string
	isRustLinked(): boolean
	startShare(requestJson: string, callback: DashbeamEventCallback): string
	startReceive(requestJson: string, callback: DashbeamEventCallback): string
	fetchMetadata(requestJson: string, callback: DashbeamEventCallback): string
	startNode(requestJson: string, callback: DashbeamEventCallback): string
	stopNode(requestJson: string): string
	nodeCommand(requestJson: string, callback: DashbeamEventCallback): string
	nodeStatus(): string
	cancelOperation(requestJson: string): string
	getSessionStatus(requestJson: string): string
	resolveFileUri(uri: string): string
}

declare const nativeEngine: DashbeamEngineModule
export default nativeEngine
