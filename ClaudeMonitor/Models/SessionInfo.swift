import Foundation

struct SessionInfo {
    var projectPath: String
    var lastActivity: Date
    var currentStatus: String? = nil
    var inProgressTasks: [TaskItem] = []
    var isProcessing: Bool = false
}
