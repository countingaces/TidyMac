import Foundation

// Conformed to by every cleanup/scan module's view model. The associated
// ResultType is a concrete struct conforming to ScanResult, so a generic
// ModuleView<M: ScanModule> can render any module without knowing the
// specific result shape.
protocol ScanModule: ObservableObject {
    associatedtype ResultType: ScanResult

    var moduleInfo: ModuleInfo { get }
    var scanState: ScanState { get set }
    var results: [ScanCategory<ResultType>] { get set }

    var totalCleanableSize: Int64 { get }
    var selectedSize: Int64 { get }

    func startScan() async
    func cancelScan()
    func clean(items: [ResultType]) async throws
}

// Default implementations that any conformer can override.
extension ScanModule {
    var totalCleanableSize: Int64 {
        results.reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var selectedSize: Int64 {
        results
            .filter { $0.isSelected }
            .reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    var hasResults: Bool {
        scanState == .complete && !results.isEmpty
    }
}
