import Foundation
import os

public enum KnowledgeLogger {
    static let database = Logger(subsystem: "ai.osaurus", category: "knowledge.database")
    static let index = Logger(subsystem: "ai.osaurus", category: "knowledge.index")
    static let search = Logger(subsystem: "ai.osaurus", category: "knowledge.search")
}
