import Foundation

struct SessionInfo: Identifiable {
    var id: String           // session UUID (JSONL filename without extension)
    var projectPath: String
    var lastActivity: Date
    var currentStatus: String? = nil
    var inProgressTasks: [TaskItem] = []
    var isProcessing: Bool = false
    var isCompacting: Bool = false
    var sessionCost: Double = 0
    var sessionTokens: Int = 0
}
