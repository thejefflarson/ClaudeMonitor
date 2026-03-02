import Foundation

struct SessionInfo: Identifiable {
    var id: String           // session UUID (JSONL filename without extension)
    var projectPath: String
    var lastActivity: Date
    var currentStatus: String? = nil
    var inProgressTasks: [TaskItem] = []
    var isProcessing: Bool = false
    var isCompacting: Bool = false
}
