import Foundation

struct SessionInfo {
    var projectPath: String
    var lastActivity: Date
    var inProgressTasks: [TaskItem] = []
}
