import os

enum AppLog {
    static let app = Logger(subsystem: "me.harke.bam", category: "app")
    static let config = Logger(subsystem: "me.harke.bam", category: "config")
    static let control = Logger(subsystem: "me.harke.bam", category: "control")
    static let router = Logger(subsystem: "me.harke.bam", category: "router")
}
