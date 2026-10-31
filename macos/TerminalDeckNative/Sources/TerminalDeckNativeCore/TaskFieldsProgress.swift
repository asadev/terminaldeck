import Foundation

extension TaskFields {
    // MARK: Progress

    public static func autoProgress(_ config: FieldConfig, _ auto: AutoProgress?) -> (done: Int, total: Int, percent: Int) {
        guard let auto else { return (0, 0, 0) }
        let done = (config.subtasks != false ? auto.subtasksDone : 0) + (config.checklists != false ? auto.checklistsDone : 0)
        let total = (config.subtasks != false ? auto.subtasksTotal : 0) + (config.checklists != false ? auto.checklistsTotal : 0)
        return (done, total, total > 0 ? Int(jsRound(Double(done) / Double(total) * 100)) : 0)
    }

    public static func manualPercent(_ config: FieldConfig, _ value: Double?) -> Int {
        guard let value else { return 0 }
        let start = config.start ?? 0
        let end = config.end ?? 100
        return Int(jsRound(Swift.min(100, Swift.max(0, (value - start) / (end - start) * 100))))
    }

}
