import os

/// Unified logger for the audio engine. View with:
///   log show --predicate 'subsystem == "me.harke.bam"' --last 5m --info
/// or stream live:
///   log stream --predicate 'subsystem == "me.harke.bam"'
let engineLog = Logger(subsystem: "me.harke.bam", category: "audio")

/// Engine-wide log helper. Existing call sites pass just a message (debug level);
/// failure paths can raise the level so they surface in Console without `--debug`.
func bamLog(_ msg: String, level: OSLogType = .debug) {
    engineLog.log(level: level, "\(msg, privacy: .public)")
}
