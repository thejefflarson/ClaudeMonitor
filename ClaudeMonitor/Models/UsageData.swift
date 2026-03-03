import Foundation

struct DailyCost: Identifiable {
    var date: Date
    var cost: Double
    var id: Date { date }
}

struct UsageData {
    var tokensUsed: Int = 0
    var costUSD: Double = 0.0
    var dailyCosts: [DailyCost] = []
    var periodStart: Date?
    var lastFetched: Date?
}
