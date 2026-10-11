import HPLCore

public enum InsightEngines {
    /// Apple Foundation Models where the SDK has it; otherwise rules only. Availability (device, Apple Intelligence
    /// setting, model download) is re-checked on every run and the pipeline falls back to rules when it's missing.
    public static func preferred() -> any InsightEngine {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { return FoundationModelsEngine() }
        #endif
        return RulesOnlyEngine()
    }

    /// Human label for Settings.
    public static func status(of engine: any InsightEngine) async -> String {
        switch await engine.isAvailable() {
        case .available: engine.generator.engine == .rules ? "Rules only" : "On-device model (\(engine.id))"
        case .unavailable(let reason): "Rules only: \(reason)"
        }
    }
}
