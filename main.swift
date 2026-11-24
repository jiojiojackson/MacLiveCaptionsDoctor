// LiveCaptionsDoctor — 实时字幕（Live Captions）语言模型诊断工具
// 需要 macOS 26 或更新版本（使用 SpeechAnalyzer / AssetInventory 系统 API）
// 编译：bash build.sh

import SwiftUI
import AppKit
import Speech
import Network
import Foundation

// MARK: - 通用工具函数

struct CmdResult: Sendable {
    let status: Int32
    let output: String
}

/// 运行命令行程序（stdout + stderr 合并），带超时
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval) -> CmdResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return CmdResult(status: -1, output: "无法启动 \(path)：\(error.localizedDescription)")
    }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return CmdResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "未知" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "未知" }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func describeError(_ error: Error) -> String {
    let ns = error as NSError
    var s = "\(error.localizedDescription) | domain=\(ns.domain) code=\(ns.code)"
    if !ns.userInfo.isEmpty { s += " | userInfo=\(ns.userInfo)" }
    s += " | raw=\(String(describing: error))"
    return s
}

func localeKey(_ l: Locale) -> String { l.identifier(.bcp47) }

func displayName(_ id: String) -> String {
    Locale.current.localizedString(forIdentifier: id) ?? id
}

// MARK: - 数据模型

enum ModStatus: String {
    case notOffered = "—"
    case unsupported = "不支持"
    case supported = "未下载"
    case downloading = "下载中"
    case installed = "已安装"
    case systemInstalled = "系统已有"
    case unknown = "未知"

    var color: Color {
        switch self {
        case .installed: return .green
        case .systemInstalled: return .green
        case .supported: return .red
        case .downloading: return .blue
        case .unknown: return .orange
        default: return .secondary
        }
    }
}

func mapStatus(_ s: AssetInventory.Status) -> ModStatus {
    switch s {
    case .installed: return .installed
    case .downloading: return .downloading
    case .supported: return .supported
    case .unsupported: return .unsupported
    @unknown default: return .unknown
    }
}

enum Overall: String, CaseIterable, Identifiable {
    static var allCases: [Overall] { [.ready, .downloading, .needsDownload, .unsupported] }
    case ready = "已就绪"
    case partial = "部分就绪"
    case downloading = "下载中"
    case needsDownload = "需下载"
    case unsupported = "实时字幕不支持"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .ready: return .green
        case .partial: return .orange
        case .downloading: return .blue
        case .needsDownload: return .red
        case .unsupported: return .gray
        }
    }
}

struct LangRow: Identifiable {
    let id: String
    let locale: Locale
    let name: String
    var speech: ModStatus = .notOffered      // SpeechTranscriber（通用转写模型）
    var dictation: ModStatus = .notOffered   // DictationTranscriber（听写模型）
    var legacyOnDevice: Bool? = nil          // 旧版 SFSpeechRecognizer 是否支持离线
    var reserved = false
    var progress: Double? = nil
    var progressText = ""
    var lastError: String? = nil

    /// 实时字幕使用 SpeechTranscriber（com.apple.speech.asr.transcription.<语言>），只看“转写模型”
    var overall: Overall {
        if progress != nil { return .downloading }
        switch speech {
        case .installed, .systemInstalled: return .ready
        case .downloading: return .downloading
        case .supported, .unknown: return .needsDownload
        default: return .unsupported
        }
    }

    var dictationMissing: Bool { dictation == .supported || dictation == .unknown }
}

struct SysJob: Identifiable {
    let id: String          // mobileassetd 任务 UUID
    var name: String
    var expected: Int64 = 0
    var written: Int64 = 0
    var remaining: Double = -1
    var stalled = false
    var finished = false
    var updated = Date.distantPast
    var speed: Double = 0   // 字节/秒
    var fraction: Double { expected > 0 ? min(1, Double(written) / Double(expected)) : 0 }
}

func friendlyAssetName(_ raw: String) -> String {
    let map: [String: String] = [
        "UAF_Siri_Understanding": "Siri 语音理解（听写/识别模型）",
        "UAF_Siri_UnderstandingASRHammer": "语音识别（ASR Hammer）",
        "UAF_Siri_TextToSpeech": "Siri 语音朗读（TTS，与字幕无关）",
        "UAF_Speech_AutomaticSpeechRecognition": "语音识别模型（ASR）",
    ]
    return map[raw] ?? raw
}

let sysLogDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func firstMatch(_ pattern: String, in s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    var out: [String] = []
    for i in 0..<m.numberOfRanges {
        if let r = Range(m.range(at: i), in: s) { out.append(String(s[r])) } else { out.append("") }
    }
    return out
}

enum LogLevel: String { case info = "INFO", warn = "WARN", error = "ERROR" }

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let source: String
    let text: String
}

func logLevel(forSystemLine line: String) -> LogLevel {
    // compact 格式：2026-11-24 19:16:01.123 E  process[pid:tid] ...
    let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    if parts.count >= 3 {
        let t = parts[2]
        if t == "E" || t == "F" || t == "Fa" { return .error }
    }
    var l = line.lowercased()
    // 去掉表示“没问题”的字段 / ObjC 方法名里的 error: 参数，避免误判为警告
    for ok in ["stalled:n", "isstalled: no", "isstalled:no", "numstalls: 0", "numnolongerstalls", "error:(null)", "error: (null)", "error=(null)", "error:nil", "error:n|", "error:n,", "error:n]", "attempted:n", "failed:0", "failures:0", ":error:]", ":error:", "error:]", "samversionfound", "sameversionfound"] {
        l = l.replacingOccurrences(of: ok, with: " ")
    }
    if l.contains(" success") && !l.contains("fail") { return .info }
    // 用单词边界匹配，避免 "installed" 被当成 "stalled"
    let warnPattern = "\\b(error|errors|fail|failed|failure|denied|timeout|timed out|stalled|insufficient|not entitled)\\b"
    if l.range(of: warnPattern, options: .regularExpression) != nil { return .warn }
    return .info
}

/// 比较版本号（按 . 或 , 分段数字比较）：<0 表示 a 更旧
func compareVersions(_ a: String, _ b: String) -> Int {
    let pa = a.split(whereSeparator: { $0 == "." || $0 == "," }).map { Int($0) ?? 0 }
    let pb = b.split(whereSeparator: { $0 == "." || $0 == "," }).map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

func formatDuration(_ secs: Double) -> String {
    if !secs.isFinite || secs < 0 { return "—" }
    let t = Int(secs.rounded())
    if t < 60 { return "\(t)秒" }
    if t < 3600 { return "\(t / 60)分\(t % 60)秒" }
    return "\(t / 3600)小时\((t % 3600) / 60)分"
}

func formatMB(_ bytes: Int64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

/// 去掉时间戳、pid:tid、十六进制地址、UUID，用于识别“同一条”日志
func normalizeLogLine(_ line: String) -> String {
    var s = line
    let parts = s.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    if parts.count == 4 { s = String(parts[2]) + " " + String(parts[3]) }
    let patterns = ["\\[\\d+:[0-9a-fA-F]+\\]", "0x[0-9a-fA-F]+", "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<\\d+>"]
    for p in patterns {
        s = s.replacingOccurrences(of: p, with: "#", options: .regularExpression)
    }
    return s
}

/// 本工具探测时必然出现、无害的系统日志
func isKnownNoise(_ line: String) -> Bool {
    let noise = [
        "No asset found with name: com.apple.siri.asr.assistant",
        "No Assistant asset for language",
        // 以下是“未签名的小工具”启动时系统常见的无害报错
        "com.apple.linkd.autoShortcut",
        "Error registering app with AppIntents",
        "Will NOT re-try to establish the connection",
        "Unable to obtain a task name port right",
        "DetachedSignatures",
        "cannot open file at line",
        "should not be called on the main thread",
        "NSSecureCoding allowed classes list contains",
        "Process start to XPC connection ready in",
        "Domain: com.apple.triald",
        "ViewBridge to RemoteViewService Terminated",
        "No registration from client for: com.apple.siri.bg_system_task",
        "libMobileGestalt",
        "[com.apple.AppKit:Gestures]",
        "Failed to request donation",
        "[com.apple.corespotlight",
        "TTS: isSpeakingPropertyList was nil",
        "[com.apple.PerfPowerServices",
        "IMKCFRunLoopWakeUpReliable",
        // 实时字幕进程自身的常见无害报错（字幕正常时也会出现）
        "error calculating exclusion region",
        "Couldn't write values for keys",
        "AudioObjectGetPropertyData: no object",
        "AudioObjectRemovePropertyListenerBlock",
        "MTDRunningStateListener",
        "HALC_",
        "AggregateDevice.mm",
        "Unexpected pending ane model initialization",
        // 本工具界面绘制相关
        "libCoreFSCache",
        "[com.apple.AppKit:NSCGS]",
        "[com.apple.coreanimation:API]",
        "Invalid attempt to open a new transaction during CA commit",
        // 每次系统下载都会出现，下载照常进行
        "nw_parameters_set_source_application_by_bundle_id_internal",
        "Network Delegation Failure: Invalid Bundle ID",
    ]
    for n in noise where line.contains(n) { return true }
    return false
}

/// 读取 MobileAsset 资源的 Info.plist，提取语言/类型/版本等关键信息
func describeAsset(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    guard let dict = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any] else {
        return name + "（无法读取 Info.plist）"
    }
    var props: [String: Any] = dict
    if let m = dict["MobileAssetProperties"] as? [String: Any] { props = m }
    let wanted = ["locale", "language", "lang", "assettype", "assetspecifier", "assetname", "name", "version", "usage", "specifier", "task", "purpose", "region"]
    var parts: [String] = []
    for k in props.keys.sorted() {
        let lk = k.lowercased()
        var match = false
        for w in wanted where lk.contains(w) { match = true }
        if !match { continue }
        let v = String(describing: props[k]!)
        if v.count > 120 { continue }
        parts.append(k + "=" + v)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path + "/AssetData"))?[.size] as? Int
    var s: String = String(name.prefix(12)) + "…  " + parts.joined(separator: "  ")
    if size != nil { s += "  [AssetData 存在]" }
    return s
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

let logStartFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

let systemLogPredicate = """
(process CONTAINS[c] "LiveTranscription" OR process CONTAINS[c] "LiveCaption" OR process == "Live Captions" OR process CONTAINS[c] "Live Caption" \
OR subsystem CONTAINS[c] "livecaption" OR subsystem CONTAINS[c] "livetranscription" OR process CONTAINS[c] "LiveCaptionsDoctor" \
OR (process CONTAINS[c] "transcri" AND NOT process CONTAINS[c] "ImageCaption") OR process CONTAINS[c] "corespeech" \
OR eventMessage CONTAINS "Locked asset set" OR eventMessage CONTAINS "Transcriber initialized with locale" \
OR subsystem CONTAINS[c] "LiveTranscription" OR subsystem CONTAINS[c] "LiveCaption") \
OR ((process CONTAINS[c] "speech" OR subsystem CONTAINS[c] "speech") AND (messageType == error OR messageType == fault \
OR eventMessage CONTAINS[c] "asset" OR eventMessage CONTAINS[c] "locale" OR eventMessage CONTAINS[c] "download" OR eventMessage CONTAINS[c] "install")) \
OR ((process CONTAINS[c] "mobileasset" OR process == "assetsd" OR process CONTAINS[c] "ModelCatalog" OR subsystem CONTAINS[c] "MobileAsset" OR subsystem CONTAINS[c] "UnifiedAsset") \
AND (eventMessage CONTAINS[c] "speech" OR eventMessage CONTAINS[c] "asr" OR eventMessage CONTAINS[c] "dictation" OR eventMessage CONTAINS[c] "transcri" \
OR eventMessage CONTAINS[c] "UAF_Siri" OR eventMessage CONTAINS[c] "Stalled" OR eventMessage CONTAINS[c] "caption")) \
OR (process == "mobileassetd" AND eventMessage CONTAINS "(progress) [expectedBytes:")
"""

// MARK: - 诊断逻辑

@MainActor
final class DoctorModel: ObservableObject {
    @Published var rows: [LangRow] = []
    @Published var logs: [LogEntry] = []
    @Published var isRefreshing = false
    @Published var isFetchingLogs = false
    @Published var envLines: [String] = []
    @Published var reservedLocales: [Locale] = []
    @Published var maxReserved = 0
    @Published var autoRefresh = true
    @Published var collectSystemLogs = true
    @Published var lastRefresh: Date?

    private var pendingRefresh = false
    private var started = false
    var downloadTasks: [String: Task<Void, Never>] = [:]
    private var progresses: [String: Progress] = [:]
    private var lastLogFetch = Date().addingTimeInterval(-30 * 60)   // 首次抓取最近 30 分钟
    private var seenLines = Set<String>()
    private var warnedMismatch = Set<String>()
    private var legacyCache: [String: Bool?] = [:]
    private var mismatchNotes: [String] = []
    private var seenPatterns: [String: Int] = [:]
    @Published var foldedCount = 0
    @Published var noiseCount = 0

    let preferredLanguageCodes: Set<String> = Set(Locale.preferredLanguages.compactMap {
        Locale(identifier: $0).language.languageCode?.identifier
    })

    var errorCount: Int { logs.filter { $0.level == .error }.count }

    // MARK: 启动
    func start() {
        guard !started else { return }
        started = true
        log(.info, "App", "实时字幕语言诊断工具启动")
        startNetworkMonitor()
        Task {
            await collectEnvironment()
            await refresh()
            await fetchSystemLogs()
            checkModels()
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                // 测试期间暂停自动检测，避免本工具自己的查询混入测试数据
                if self.autoRefresh && !self.isTesting { await self.refresh(quiet: true) }
                await self.checkProcesses()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.collectSystemLogs { await self.fetchSystemLogs() }
                // 有下载进行时每 8 秒抓一次（拿系统下载的真实 MB/速度），否则 20 秒
                let busy = !self.downloadTasks.isEmpty || !self.activeSysJobs.isEmpty || self.lcReady == false
                try? await Task.sleep(nanoseconds: busy ? 8_000_000_000 : 20_000_000_000)
            }
        }
    }

    func log(_ level: LogLevel, _ source: String, _ text: String) {
        logs.append(LogEntry(time: Date(), level: level, source: source, text: text))
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
    }

    func clearLogs() {
        logs.removeAll()
        log(.info, "App", "日志已清空")
    }

    private func setRow(_ id: String, _ change: (inout LangRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }

    // MARK: 环境信息
    func collectEnvironment() async {
        var lines: [String] = []
        lines.append("macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)（\(sysctlString("kern.osversion"))）")
        lines.append("机型：\(sysctlString("hw.model"))，芯片：\(sysctlString("machdep.cpu.brand_string"))，内存：\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            lines.append("可用磁盘空间：\(ByteCountFormatter.string(fromByteCount: v, countStyle: .file))")
            if v < 5_000_000_000 { log(.warn, "Env", "可用磁盘空间不足 5 GB，语言模型可能无法下载") }
        }
        lines.append("系统首选语言：\(Locale.preferredLanguages.joined(separator: ", "))；区域：\(Locale.current.identifier)")
        lines.append("语音识别权限：\(authText(SFSpeechRecognizer.authorizationStatus()))")
        let procs = await scanSpeechProcesses()
        lastProcs = procs
        lines.append("语音/字幕相关进程：" + (procs.isEmpty ? "无" : procs.sorted().joined(separator: ", ")))
        envLines = lines
        for l in lines { log(.info, "Env", l) }
    }

    func authText(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .notDetermined: return "未询问"
        @unknown default: return "未知(\(s.rawValue))"
        }
    }

    func requestSpeechAuth() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.log(.info, "Auth", "语音识别权限结果：\(self.authText(status))")
                await self.collectEnvironment()
            }
        }
    }

    // MARK: 检测语言状态
    func refresh(quiet: Bool = false) async {
        if isRefreshing { pendingRefresh = true; return }
        isRefreshing = true
        if !quiet { log(.info, "App", "开始检测语言模型状态…") }

        let speechSupported = await SpeechTranscriber.supportedLocales
        let speechInstalled = await SpeechTranscriber.installedLocales
        let dictSupported = await DictationTranscriber.supportedLocales
        let dictInstalled = await DictationTranscriber.installedLocales
        let reserved = await AssetInventory.reservedLocales
        reservedLocales = reserved
        maxReserved = AssetInventory.maximumReservedLocales

        if speechSupported.isEmpty && dictSupported.isEmpty {
            log(.error, "Check", "系统没有返回任何可用语言（SpeechTranscriber / DictationTranscriber 均为空）。可能是系统语音服务异常或此 Mac 不支持。")
        }

        let legacy = SFSpeechRecognizer.supportedLocales()
        var legacyMap: [String: Locale] = [:]
        for l in legacy { legacyMap[localeKey(l)] = l }

        var all: [String: Locale] = [:]
        for l in speechSupported + dictSupported where all[localeKey(l)] == nil { all[localeKey(l)] = l }
        let speechSet = Set(speechSupported.map(localeKey))
        let dictSet = Set(dictSupported.map(localeKey))
        let speechInst = Set(speechInstalled.map(localeKey))
        let dictInst = Set(dictInstalled.map(localeKey))
        let reservedSet = Set(reserved.map(localeKey))

        var newRows: [LangRow] = []
        for (id, locale) in all {
            var row = LangRow(id: id, locale: locale, name: displayName(id))
            if speechSet.contains(id) {
                let m = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                row.speech = mapStatus(await AssetInventory.status(forModules: [m]))
                checkMismatch(id: id, kind: "转写", status: row.speech, listedInstalled: speechInst.contains(id))
                if row.speech == .supported && speechInst.contains(id) { row.speech = .systemInstalled }
            }
            if dictSet.contains(id) {
                let m = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                row.dictation = mapStatus(await AssetInventory.status(forModules: [m]))
                checkMismatch(id: id, kind: "听写", status: row.dictation, listedInstalled: dictInst.contains(id))
                if row.dictation == .supported && dictInst.contains(id) { row.dictation = .systemInstalled }
            }
            if let ll = legacyMap[id] {
                // 只在第一次检测时查询（每次查询都会让系统打印 "No asset found ... siri.asr.assistant" 错误）
                if let cached = legacyCache[id] {
                    row.legacyOnDevice = cached
                } else {
                    let v: Bool? = SFSpeechRecognizer(locale: ll)?.supportsOnDeviceRecognition
                    legacyCache.updateValue(v, forKey: id)
                    row.legacyOnDevice = v
                }
            }
            row.reserved = reservedSet.contains(id)
            newRows.append(row)
        }
        newRows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // 合并正在进行的下载状态（使用最新的 rows）
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for i in newRows.indices {
            if let old = current[newRows[i].id] {
                newRows[i].progress = old.progress
                newRows[i].progressText = old.progressText
                newRows[i].lastError = old.lastError
            }
        }
        if !current.isEmpty {
            for r in newRows {
                if let o = current[r.id]?.overall, o != r.overall {
                    log(.info, "Status", "\(r.name) [\(r.id)]：\(o.rawValue) → \(r.overall.rawValue)")
                }
            }
        }
        rows = newRows
        lastRefresh = Date()

        if !quiet {
            let c = Dictionary(grouping: newRows, by: { $0.overall }).mapValues(\.count)
            log(.info, "Check", "检测完成：共 \(newRows.count) 种语言；已就绪 \(c[.ready] ?? 0)，下载中 \(c[.downloading] ?? 0)，需下载 \(c[.needsDownload] ?? 0)，实时字幕不支持 \(c[.unsupported] ?? 0)（判断依据：转写模型）")
            log(.info, "Check", "本工具预留语言 \(reserved.count)/\(maxReserved)：\(reserved.map(localeKey).joined(separator: ", "))")
            if !mismatchNotes.isEmpty {
                log(.info, "Check", "以下模型系统里已经装好（由系统或其他功能下载，不属于本工具），显示为“系统已有”：\(mismatchNotes.joined(separator: ", "))")
                mismatchNotes.removeAll()
            }
        }

        isRefreshing = false
        if pendingRefresh {
            pendingRefresh = false
            await refresh(quiet: true)
        }
    }

    private func checkMismatch(id: String, kind: String, status: ModStatus, listedInstalled: Bool) {
        // 常见情况：模型已被系统（或其他 App，例如听写/实时字幕）装好，但不属于本工具，
        // 此时 AssetInventory.status 返回“未下载”，而 installedLocales 列表包含它。显示为“系统已有”，只记一次日志。
        let key = "\(kind)-\(id)-\(status.rawValue)-\(listedInstalled)"
        if warnedMismatch.contains(key) { return }
        warnedMismatch.insert(key)
        if status == .supported && listedInstalled {
            mismatchNotes.append("\(id)(\(kind))")
        } else if status == .installed && !listedInstalled {
            log(.warn, "Check", "\(displayName(id)) [\(id)] \(kind)模型：AssetInventory 显示已安装，但 installedLocales 不包含")
        }
    }

    // MARK: 下载
    /// 逐个模块下载（转写、听写分开），一个卡住不影响另一个；带卡住检测
    /// includeDictation=false：只下载实时字幕需要的转写模型（更小更快）
    func download(_ id: String, includeDictation: Bool = false) {
        guard downloadTasks[id] == nil, let row = rows.first(where: { $0.id == id }) else { return }
        let locale = row.locale
        let name = row.name
        var plan: [String] = []
        if row.speech == .supported || row.speech == .downloading || row.speech == .unknown { plan.append("转写") }
        if includeDictation && (row.dictation == .supported || row.dictation == .downloading || row.dictation == .unknown) { plan.append("听写") }
        if plan.isEmpty {
            log(.info, "Download", "\(name) [\(id)] 没有需要下载的模块")
            return
        }
        setRow(id) { $0.progress = 0; $0.progressText = "准备中…"; $0.lastError = nil }
        log(.info, "Download", "\(name) [\(id)] 开始下载，模块：\(plan.joined(separator: "、"))｜网络：\(networkText)")

        downloadTasks[id] = Task { [weak self] in
            guard let self else { return }
            var failed: [String] = []
            for (idx, kind) in plan.enumerated() {
                if Task.isCancelled { break }
                let prefix = plan.count > 1 ? "[\(idx + 1)/\(plan.count) \(kind)] " : "[\(kind)] "
                do {
                    let module: any SpeechModule
                    if kind == "转写" {
                        module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                    } else {
                        module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                    }
                    let t0 = Date()
                    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                        self.log(.info, "Download", "\(name) [\(id)] \(kind)模型：系统表示已安装，无需下载")
                        continue
                    }
                    let progress = request.progress
                    self.progresses[id] = progress
                    self.log(.info, "Download", "\(name) [\(id)] \(kind)模型：已拿到下载请求（耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s），总量 \(progress.totalUnitCount)，不确定进度=\(progress.isIndeterminate)")
                    let poller = Task { @MainActor [weak self] in
                        var lastBucket = -1
                        var lastFraction: Double = -1
                        var lastChange = Date()
                        var stallWarned = 0
                        let start = Date()
                        var samples: [(Date, Double)] = []   // 最近 60 秒的进度样本，用于算速度/剩余时间
                        while !Task.isCancelled {
                            let now = Date()
                            let f = progress.fractionCompleted
                            let pct = Int(f * 100)
                            // 用 fractionCompleted 判断是否有进展（completedUnitCount 在完成前一直是 0）
                            if f > lastFraction + 0.0005 {
                                lastFraction = f
                                lastChange = now
                            }
                            samples.append((now, f))
                            samples.removeAll { now.timeIntervalSince($0.0) > 60 }
                            let elapsed = Int(now.timeIntervalSince(start))
                            let idle = Int(now.timeIntervalSince(lastChange))

                            var text = prefix + String(format: "%.1f%%", f * 100)
                            if let extra = progress.localizedAdditionalDescription, !extra.isEmpty {
                                text += " · " + extra
                            }
                            if let first = samples.first, now.timeIntervalSince(first.0) >= 10 {
                                let rate = (f - first.1) / now.timeIntervalSince(first.0)   // 每秒完成比例
                                if rate > 0 {
                                    text += String(format: " · %.1f%%/分", rate * 6000)
                                    text += " · 剩余约 " + formatDuration((1 - f) / rate)
                                }
                            }
                            text += " · 已用 " + formatDuration(Double(elapsed))
                            if idle >= 30 { text += " · ⚠️ " + formatDuration(Double(idle)) + " 无变化" }
                            if let sys = self?.systemJobSummary(), !sys.isEmpty { text += "\n系统下载：" + sys }
                            self?.setRow(id) {
                                $0.progress = f
                                $0.progressText = text
                            }
                            if pct / 10 != lastBucket {
                                lastBucket = pct / 10
                                self?.log(.info, "Download", "\(name) [\(id)] \(kind)模型进度 \(pct)%（已用 \(formatDuration(Double(elapsed)))）")
                            }
                            if idle >= 60 && idle / 60 > stallWarned {
                                stallWarned = idle / 60
                                let net = self?.networkText ?? ""
                                self?.log(.warn, "Download", "\(name) [\(id)] \(kind)模型已 \(idle) 秒没有进度（停在 \(pct)%）。网络：\(net)。可试试「重启下载服务」。")
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                    defer { poller.cancel() }
                    try await request.downloadAndInstall()
                    self.log(.info, "Download", "✅ \(name) [\(id)] \(kind)模型下载并安装完成（耗时 \(Int(Date().timeIntervalSince(t0)))s）")
                } catch is CancellationError {
                    self.log(.warn, "Download", "\(name) [\(id)] 下载已取消")
                    break
                } catch {
                    failed.append(kind)
                    self.log(.error, "Download", "\(name) [\(id)] \(kind)模型下载失败：\(describeError(error))")
                    self.setRow(id) { $0.lastError = kind + "：" + error.localizedDescription }
                    if self.reservedLocales.count >= self.maxReserved && self.maxReserved > 0 {
                        self.log(.warn, "Download", "提示：本工具的语言预留名额已满（\(self.reservedLocales.count)/\(self.maxReserved)），可在“预留语言”里释放不用的语言后重试。")
                    }
                }
                self.progresses[id] = nil
                await self.refresh(quiet: true)
            }
            self.setRow(id) { $0.progress = nil; $0.progressText = "" }
            self.progresses[id] = nil
            self.downloadTasks[id] = nil
            await self.refresh(quiet: true)
        }
    }

    // MARK: 网络与下载服务
    @Published var networkText = "检测中…"
    @Published var sysJobs: [String: SysJob] = [:]
    // 进程监视 & 实时字幕测试
    var lastProcs = Set<String>()
    @Published var testRemaining = 0
    private var testStart: Date?
    private var testNewProcs = Set<String>()
    private var lockEvents: [(Date, String, String)] = []      // (时间, 进程, 资源集)
    private var transcriberEvents: [(Date, String)] = []        // (时间, 进程)
    private var liveCaptionEvents: [(Date, String)] = []        // 实时字幕进程自己的日志
    private var asrLangEvents: [(Date, String, String)] = []    // (时间, 进程, 语言)
    var isTesting: Bool { testStart != nil }

    // 实时字幕实时状态（从 Live Captions 进程日志解析）
    @Published var lcLocale = ""
    @Published var lcState = "未知（等待日志）"
    @Published var lcReady: Bool? = nil
    @Published var lcProgress: Int? = nil
    @Published var lcLastCaption: Date? = nil
    @Published var lcCaptionCount = 0
    private var lcCaptionEvents: [(Date, String)] = []
    private var lcSkipEvents: [(Date, String, Int)] = []
    private var lcWarnBucket: [String: Int] = [:]
    // 转写模型描述（来自 mobileassetd 日志）：语言代码 -> (版本, ID, 下载字节, 安装字节)
    var asrDescriptors: [String: (String, String, Int64, Int64)] = [:]
    @Published var modelLines: [String] = []

    /// 列出名字里含 caption / transcri / speech / asr / dictation 的进程（不含本工具）
    func scanSpeechProcesses() async -> Set<String> {
        let r = await Task.detached { runCommand("/bin/ps", ["-axo", "comm="], timeout: 5) }.value
        var out = Set<String>()
        let keys = ["caption", "transcri", "speech", "asr", "dictation"]
        for raw in r.output.split(separator: "\n") {
            let name = (String(raw) as NSString).lastPathComponent
            let low = name.lowercased()
            if low.contains("livecaptionsdoctor") || low.contains("imagecaption") { continue }
            for k in keys where low.contains(k) { out.insert(name); break }
        }
        return out
    }

    func checkProcesses() async {
        let now = await scanSpeechProcesses()
        let started = now.subtracting(lastProcs)
        let stopped = lastProcs.subtracting(now)
        if !started.isEmpty {
            log(.info, "Proc", "▶︎ 进程启动：" + started.sorted().joined(separator: ", "))
            if testStart != nil { testNewProcs.formUnion(started) }
        }
        if !stopped.isEmpty { log(.info, "Proc", "■ 进程退出：" + stopped.sorted().joined(separator: ", ")) }
        lastProcs = now
    }

    /// 从系统日志行里记录“哪个进程锁定了哪个语音资源集”“谁初始化了转写器”
    func trackSpeechUsage(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return }
        let rest = String(parts[3]).trimmingCharacters(in: .whitespaces)
        // 进程名可能带空格（例如 "Live Captions"），取到 "[" 为止
        let proc = String(rest.prefix { $0 != "[" }).trimmingCharacters(in: .whitespaces)
        let ts = sysLogDateFormatter.date(from: String(line.prefix(23))) ?? Date()
        if proc == "Live Captions" {
            liveCaptionEvents.append((ts, rest))
            if liveCaptionEvents.count > 5000 { liveCaptionEvents.removeFirst(1000) }
            parseLiveCaptionLine(rest, ts: ts)
        }
        if let m = firstMatch("specifier:com\\.apple\\.speech\\.asr\\.transcription\\.([A-Za-z_]+)\\|version:([0-9.]+)[^|]*\\|ID:([0-9a-f]+)", in: rest) {
            var net: Int64 = 0
            var fsz: Int64 = 0
            if let d = firstMatch("\\(downloaded\\)user:[YN],network:(\\d+),filesystem:(\\d+)", in: rest) {
                net = Int64(d[1]) ?? 0
                fsz = Int64(d[2]) ?? 0
            }
            let old = asrDescriptors[m[1]]
            asrDescriptors[m[1]] = (m[2], m[3], net, fsz)
            if old == nil || old!.0 != m[2] {
                log(.info, "Model", "转写模型 [\(m[1])] 版本 \(m[2])，安装大小 \(formatMB(fsz))（来自系统日志）")
            }
        }
        if let m = firstMatch("\"asr\\.language\" = \"?([A-Za-z_\\-]+)", in: rest) {
            asrLangEvents.append((ts, proc, m[1]))
            if asrLangEvents.count > 5000 { asrLangEvents.removeFirst(1000) }
        }
        if let m = firstMatch("Locked asset set ([A-Za-z0-9_.]+)", in: rest) {
            lockEvents.append((ts, proc, m[1]))
            if lockEvents.count > 5000 { lockEvents.removeFirst(1000) }
        } else if rest.contains("Transcriber initialized with locale") {
            transcriberEvents.append((ts, proc))
            if transcriberEvents.count > 5000 { transcriberEvents.removeFirst(1000) }
        }
    }

    func parseLiveCaptionLine(_ rest: String, ts: Date) {
        let loc = "([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*)"
        if let m = firstMatch("update SelectedLocale: Optional\\(" + loc, in: rest) {
            if m[1] != lcLocale { log(.info, "LC", "实时字幕切换语言 → \(m[1])（\(displayName(m[1]))）") }
            lcLocale = m[1]
            lcReady = nil
            lcProgress = nil
            lcState = "已切换语言，等待识别…"
        } else if let m = firstMatch("APIv2 start .*locale: Optional\\(" + loc, in: rest) {
            lcLocale = m[1]
        } else if let m = firstMatch("locale: " + loc + ", assets are not ready progress: (\\d+)", in: rest) {
            let p = Int(m[2]) ?? 0
            lcLocale = m[1]
            lcReady = false
            lcProgress = p
            lcState = "⚠️ 模型未就绪（下载 \(p)%）— 声音被跳过，不会出字幕"
            lcSkipEvents.append((ts, m[1], p))
            if lcSkipEvents.count > 5000 { lcSkipEvents.removeFirst(1000) }
            let bucket = p / 10
            if lcWarnBucket[m[1]] != bucket {
                lcWarnBucket[m[1]] = bucket
                log(.warn, "LC", "实时字幕选择了 \(m[1])（\(displayName(m[1]))），但模型还没下载完（\(p)%）。这段时间的声音会被跳过，所以不出字幕。")
            }
        } else if let m = firstMatch("hasAssets: (true|false) for locale: " + loc, in: rest) {
            let ok = m[1] == "true"
            if lcReady != ok || lcLocale != m[2] {
                log(ok ? .info : .warn, "LC", "实时字幕 \(m[2])：模型\(ok ? "已就绪 ✅" : "未就绪 ⚠️")")
            }
            lcLocale = m[2]
            lcReady = ok
            if ok { lcProgress = nil }
            lcState = ok ? "✅ 模型已就绪" : "⚠️ 模型未就绪"
        } else if let m = firstMatch("AudioTranscriber: caption \\d+ .*locale: " + loc, in: rest) {
            lcLocale = m[1]
            lcReady = true
            lcProgress = nil
            lcLastCaption = ts
            lcCaptionCount += 1
            lcState = "✅ 正在出字幕"
            lcCaptionEvents.append((ts, m[1]))
            if lcCaptionEvents.count > 5000 { lcCaptionEvents.removeFirst(1000) }
        } else if rest.contains("APIv2 stop") || rest.contains("Stopping transcription") {
            lcState = "已停止识别"
        }
    }

    // MARK: 模型版本 / 完整性检查
    /// 读取系统转写模型目录（实时字幕用）：已安装资源的 Info.plist、系统目录（catalog）里的最新版本和大小，对比版本与大小
    @Published var isCheckingModels = false

    func checkModels() {
        guard !isCheckingModels else { return }
        isCheckingModels = true
        log(.info, "Model", "开始检查转写模型版本与完整性…")
        let descriptors = asrDescriptors
        Task {
            let lines: [String] = await Task.detached { () -> [String] in
                var out: [String] = []
                let fm = FileManager.default
                let base = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition"
                // 1) 找到目录（catalog）xml 和所有 .asset
                var catalogPaths: [String] = []
                var assetDirs: [String] = []
                if let en = fm.enumerator(atPath: base) {
                    while let rel = en.nextObject() as? String {
                        if rel.hasSuffix(".xml") { catalogPaths.append(base + "/" + rel) }
                        if rel.hasSuffix(".asset") {
                            assetDirs.append(base + "/" + rel)
                            en.skipDescendants()
                        }
                    }
                } else {
                    out.append("无法读取 \(base)")
                    return out
                }

                func pick(_ d: [String: Any], _ want: (String) -> Bool) -> String? {
                    for k in d.keys.sorted() where want(k.lowercased()) {
                        if let v = d[k] { return String(describing: v) }
                    }
                    return nil
                }
                func specOf(_ d: [String: Any]) -> String? { pick(d) { $0.contains("specifier") } }
                func verOf(_ d: [String: Any]) -> String? {
                    if let v = d["AssetVersion"] ?? d["_AssetVersion"] { return String(describing: v) }
                    return pick(d) { $0.contains("version") && !$0.contains("compat") && !$0.contains("os") && !$0.contains("min") && !$0.contains("max") }
                }
                func sizeOf(_ d: [String: Any]) -> Int64? {
                    for k in ["_UnarchivedSize", "UnarchivedSize", "_DownloadSize"] {
                        if let n = d[k] as? NSNumber { return n.int64Value }
                    }
                    return nil
                }

                // 2) catalog：每个 specifier 的最新版本
                var latest: [String: (String, Int64?)] = [:]
                var printedKeys = false
                for cp in catalogPaths {
                    guard let data = fm.contents(atPath: cp),
                          let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                        out.append("目录文件无法解析：" + (cp as NSString).lastPathComponent)
                        continue
                    }
                    let assets = pl["Assets"] as? [[String: Any]] ?? []
                    out.append("系统模型目录：\((cp as NSString).lastPathComponent)，\(assets.count) 个条目")
                    for a in assets {
                        if !printedKeys && a["AssetSpecifier"] == nil {
                            printedKeys = true
                            out.append("  （调试）目录条目字段：" + a.keys.sorted().joined(separator: ", "))
                        }
                        guard let sp = specOf(a), sp.contains("transcription"), let v = verOf(a) else { continue }
                        if let old = latest[sp], compareVersions(old.0, v) >= 0 { continue }
                        latest[sp] = (v, sizeOf(a))
                    }
                }

                // 3) 已安装资源
                var installed: [String: (String, Int64, String)] = [:]   // spec -> (版本, 实际大小, 目录名)
                var printedInstKeys = false
                for ad in assetDirs {
                    let id = ((ad as NSString).lastPathComponent as NSString).deletingPathExtension
                    let du = runCommand("/usr/bin/du", ["-sk", ad], timeout: 30).output
                    let kb = Int64(du.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                    var spec: String? = nil
                    var ver: String? = nil
                    if let d = NSDictionary(contentsOfFile: ad + "/Info.plist") as? [String: Any] {
                        let props = (d["MobileAssetProperties"] as? [String: Any]) ?? d
                        if !printedInstKeys && props["AssetSpecifier"] == nil {
                            printedInstKeys = true
                            out.append("  （调试）已安装资源字段：" + props.keys.sorted().joined(separator: ", "))
                        }
                        spec = specOf(props)
                        ver = verOf(props)
                    }
                    // Info.plist 读不到时，用系统日志里的描述（按 ID 匹配）
                    if spec == nil {
                        for (lang, dsc) in descriptors where dsc.1 == id {
                            spec = "com.apple.speech.asr.transcription." + lang
                            ver = dsc.0
                        }
                    }
                    let sp = spec ?? ("未知资源 " + String(id.prefix(10)))
                    installed[sp] = (ver ?? "?", kb * 1024, id)
                }

                // 4) 对比
                out.append("—— 转写模型（实时字幕用）——")
                let specs = Set(installed.keys).union(latest.keys).filter { $0.contains("transcription") || $0.hasPrefix("未知") }
                for sp in specs.sorted() {
                    let lang = sp.components(separatedBy: ".").last ?? sp
                    let inst = installed[sp]
                    let cat = latest[sp]
                    var line = "[\(lang)] "
                    if let i = inst {
                        line += "已安装 版本 \(i.0)，磁盘占用 \(formatMB(i.1))"
                        if let c = cat {
                            let cmp = compareVersions(i.0, c.0)
                            if i.0 == "?" {
                                line += "；目录最新版本 \(c.0)（已安装版本未知）"
                            } else if cmp < 0 {
                                line += "；⚠️ 有新版本 \(c.0)"
                            } else {
                                line += "；✅ 已是最新"
                            }
                            if let cs = c.1, cs > 0 {
                                let ratio = Double(i.1) / Double(cs)
                                if ratio < 0.9 {
                                    line += String(format: "；⚠️ 大小只有目录标称的 %.0f%%", ratio * 100) + "（" + formatMB(cs) + "），可能不完整"
                                } else {
                                    line += "；大小正常"
                                }
                            }
                        } else {
                            line += "；目录中没有找到对应条目"
                        }
                        if let d = descriptors[lang], d.3 > 0 {
                            let ratio = Double(i.1) / Double(d.3)
                            line += ratio < 0.9 ? String(format: "；⚠️ 实际大小只有系统记录的 %.0f%%", ratio * 100) : "；与系统记录一致"
                        }
                    } else if let c = cat {
                        line += "未安装（目录最新版本 \(c.0)" + (c.1.map { "，约 " + formatMB($0) } ?? "") + "）"
                    }
                    out.append(line)
                }
                if specs.isEmpty { out.append("没有找到转写模型资源") }
                return out
            }.value
            self.isCheckingModels = false
            self.modelLines = lines
            for l in lines {
                let lv: LogLevel = l.contains("⚠️") ? .warn : .info
                self.log(lv, "Model", l)
            }
            if let u = self.updateChecks["com.apple.speech.automaticspeechrecognition"] {
                self.log(.info, "Model", "系统最近一次检查转写模型更新：\(u.1)（\(timeFormatter.string(from: u.0))）")
            }
            self.log(.info, "Model", "模型检查完成。说明：系统会自动更新这些模型，没有公开接口可以强制更新；若显示“有新版本”，可试试「重启下载服务」让系统重新检查。")
        }
    }

    func startLiveCaptionTest() {
        guard testStart == nil else { return }
        testStart = Date()
        testNewProcs.removeAll()
        testRemaining = 90
        log(.info, "Test", "===== 实时字幕测试开始（90 秒）=====")
        log(.info, "Test", "测试期间暂停自动检测语言，避免干扰。实时字幕当前" + (lastProcs.contains("Live Captions") ? "已在运行" : "未运行"))
        log(.info, "Test", "请现在：① 打开实时字幕（控制中心或 系统设置 > 辅助功能 > 实时字幕）② 选择要测试的语言 ③ 播放一段该语言的视频或对着麦克风说话")
        Task {
            while self.testRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.testRemaining -= 1
                if self.testRemaining % 3 == 0 { await self.checkProcesses() }
                if self.testRemaining % 10 == 0 && self.testRemaining > 0 { await self.fetchSystemLogs() }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self.fetchSystemLogs()
            self.finishLiveCaptionTest()
        }
    }

    private func finishLiveCaptionTest() {
        guard let t0 = testStart else { return }
        testStart = nil
        let from = t0.addingTimeInterval(-5)
        log(.info, "Test", "===== 实时字幕测试结束 =====")
        let lcRunning = lastProcs.contains("Live Captions")
        log(lcRunning ? .info : .warn, "Test", "实时字幕进程（Live Captions）：" + (lcRunning ? "运行中 ✅" : "未运行 ⚠️"))
        log(.info, "Test", "测试期间新启动的进程：" + (testNewProcs.isEmpty ? "无" : testNewProcs.sorted().joined(separator: ", ")))

        // 实时字幕自己的日志
        let lc = liveCaptionEvents.filter { $0.0 >= from }
        log(.info, "Test", "实时字幕进程日志：\(lc.count) 条")
        var seen = Set<String>()
        var shown = 0
        for e in lc {
            let k = normalizeLogLine("x x x " + e.1)
            if seen.contains(k) { continue }
            seen.insert(k)
            log(.info, "Test", "  LC> " + String(e.1.prefix(400)))
            shown += 1
            if shown >= 40 { break }
        }

        // 实时字幕自己报告的识别结果
        let caps = lcCaptionEvents.filter { $0.0 >= from }
        var capBy: [String: Int] = [:]
        for e in caps { capBy[e.1, default: 0] += 1 }
        if capBy.isEmpty {
            log(.warn, "Test", "实时字幕产生的字幕：0 条")
        } else {
            log(.info, "Test", "实时字幕产生的字幕：" + capBy.sorted { $0.value > $1.value }.map { "\($0.key) × \($0.value) 条" }.joined(separator: "，") + " ✅")
        }
        let skips = lcSkipEvents.filter { $0.0 >= from }
        var skipBy: [String: (Int, Int, Int)] = [:]   // 次数, 最小进度, 最大进度
        for e in skips {
            let o = skipBy[e.1] ?? (0, 101, -1)
            skipBy[e.1] = (o.0 + 1, min(o.1, e.2), max(o.2, e.2))
        }
        for (loc, v) in skipBy.sorted(by: { $0.key < $1.key }) {
            log(.warn, "Test", "⚠️ \(loc)（\(displayName(loc))）模型未就绪，实时字幕跳过声音 \(v.0) 次；测试期间模型下载进度 \(v.1)% → \(v.2)%")
        }

        let locks = lockEvents.filter { $0.0 >= from && $0.1 != "LiveCaptionsDoctor" }
        var bySet: [String: Set<String>] = [:]
        for e in locks { bySet[e.2, default: []].insert(e.1) }
        if bySet.isEmpty {
            log(.info, "Test", "测试期间没有新的模型资源锁定（如果实时字幕在测试前就已开启，模型可能早已加载，属正常）")
        } else {
            for (set, procs) in bySet.sorted(by: { $0.key < $1.key }) {
                log(.info, "Test", "资源集 \(set) 被使用（经由：\(procs.sorted().joined(separator: ", "))）")
            }
        }
        let trans = transcriberEvents.filter { $0.0 >= from && $0.1 != "LiveCaptionsDoctor" }
        let tp = Set(trans.map { $0.1 })
        log(.info, "Test", "其他进程初始化转写器：\(trans.count) 次" + (tp.isEmpty ? "" : "（\(tp.sorted().joined(separator: ", "))）"))
        let errs = logs.filter { $0.time >= t0 && $0.level == .error && $0.source == "System" }
        log(errs.isEmpty ? .info : .warn, "Test", "测试期间系统错误：\(errs.count) 条" + (errs.isEmpty ? "" : "（见“系统错误”部分）"))
        log(.info, "Test", "请点「一键复制诊断报告」发给 Quick，并说明：测试的语言、实时字幕有没有出字。")
        Task { await self.refresh(quiet: true) }
    }

    private var jobLoggedBucket: [String: Int] = [:]

    var activeSysJobs: [SysJob] {
        sysJobs.values
            .filter { !$0.finished && Date().timeIntervalSince($0.updated) < 180 }
            .sorted { $0.name < $1.name }
    }

    func systemJobSummary() -> String {
        activeSysJobs.filter { !$0.name.contains("TTS") }.map { j in
            var t = j.name + " " + formatMB(j.written) + "/" + formatMB(j.expected)
            if j.speed > 0 { t += String(format: " · %.2f MB/s", j.speed / 1_048_576) }
            if j.remaining > 0 { t += " · 剩余约 " + formatDuration(j.remaining) }
            if j.stalled { t += " · ⚠️ 系统标记为卡住" }
            return t
        }.joined(separator: "；")
    }

    /// 解析 mobileassetd 的下载进度/任务名/结果日志。返回 true 表示该行已被消化，不再放进日志区
    @Published var updateChecks: [String: (Date, String)] = [:]   // 资源集 -> (时间, 结果)

    func consumeAssetLine(_ line: String) -> Bool {
        // 与语音无关的资源（Apple 智能模型目录、生成式模型、TTS）不显示
        if line.contains("mobileassetd") && (line.contains("com.apple.modelcatalog") || line.contains("UAF.FM.") || line.contains("FM.GenerativeModels")) {
            return true
        }
        // 系统自动检查更新的结果：job-task finished ... setIdentifier:<资源集> ... error:<结果>
        if line.contains("job-task finished"), let m = firstMatch("setIdentifier:([A-Za-z0-9_.]+)\\[", in: line) {
            let set = m[1]
            let speechSets = ["com.apple.speech.automaticspeechrecognition", "com.apple.siri.understanding", "com.apple.siri.asr.hammer"]
            guard speechSets.contains(set) else { return true }
            let ts = sysLogDateFormatter.date(from: String(line.prefix(23))) ?? Date()
            var result = "完成"
            var lv: LogLevel = .info
            if line.contains("SameVersionFound") {
                result = "✅ 服务器上没有更新版本（已是最新）"
            } else if let e = firstMatch("error:([A-Za-z0-9_.]+:[A-Za-z0-9]+\\(\\d+\\))", in: line) {
                result = "⚠️ " + e[1]
                lv = .warn
            } else if line.contains("NewerVersion") || line.contains("newer") {
                result = "⬇️ 发现新版本，系统将自动下载"
            }
            let old = updateChecks[set]
            updateChecks[set] = (ts, result)
            if old?.1 != result || old.map({ ts.timeIntervalSince($0.0) > 600 }) == true {
                let label = set == "com.apple.speech.automaticspeechrecognition" ? "转写模型（实时字幕用）" : (set == "com.apple.siri.understanding" ? "听写/Siri 语音理解" : "ASR Hammer")
                log(lv, "Update", "系统检查更新 · \(label)：\(result)（\(timeFormatter.string(from: ts))）")
            }
            return true
        }
        let uuidP = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        // 任务名：TaskDescriptor:com_apple_MobileAsset_UAF_Siri_Understanding.<hash>.auto.<UUID>
        if let m = firstMatch("com_apple_MobileAsset_([A-Za-z0-9_]+)\\.[0-9a-f]+\\.auto\\.(" + uuidP + ")", in: line) {
            let raw = m[1], uid = m[2]
            var j = sysJobs[uid] ?? SysJob(id: uid, name: friendlyAssetName(raw))
            j.name = friendlyAssetName(raw)
            if line.contains("MADownloadSuccessful") {
                if !j.finished { log(.info, "SysDL", "✅ 系统下载完成：\(j.name)") }
                j.finished = true
            } else if line.contains("Stalled |") || line.contains("isStalled: YES") || line.contains("isStalled:Y") {
                if !j.stalled { log(.warn, "SysDL", "系统下载被标记为卡住：\(j.name)") }
                j.stalled = true
            }
            sysJobs[uid] = j
            return false
        }
        // 进度：[UUID] (progress) [expectedBytes:..|writtenBytes:..|stalled:N|timeRemainingSecs:..]
        if let m = firstMatch("\\[(" + uuidP + ")\\] \\(progress\\) \\[expectedBytes:(\\d+)\\|writtenBytes:(\\d+)\\|stalled:([YN])\\|timeRemainingSecs:([0-9.\\-]+)", in: line) {
            let uid = m[1]
            let exp = Int64(m[2]) ?? 0, wr = Int64(m[3]) ?? 0
            let ts = sysLogDateFormatter.date(from: String(line.prefix(23))) ?? Date()
            var j = sysJobs[uid] ?? SysJob(id: uid, name: "任务 " + String(uid.prefix(8)))
            if ts > j.updated {
                let dt = ts.timeIntervalSince(j.updated)
                if j.updated != .distantPast && dt > 0 && dt < 600 && wr >= j.written {
                    let inst = Double(wr - j.written) / dt
                    j.speed = j.speed > 0 ? j.speed * 0.5 + inst * 0.5 : inst
                }
                j.expected = exp
                j.written = wr
                j.stalled = (m[4] == "Y")
                j.remaining = Double(m[5]) ?? -1
                j.updated = ts
                if exp > 0 && wr >= exp { j.finished = true }
            }
            sysJobs[uid] = j
            let bucket = Int(j.fraction * 10)
            if jobLoggedBucket[uid] != bucket {
                jobLoggedBucket[uid] = bucket
                var msg: String = j.name + "：" + formatMB(wr) + "/" + formatMB(exp)
                msg += "（\(Int(j.fraction * 100))%）"
                if j.remaining > 0 { msg += "，剩余约 " + formatDuration(j.remaining) }
                if j.stalled { msg += "，⚠️ 卡住" }
                let lv: LogLevel = j.stalled ? .warn : .info
                log(lv, "SysDL", msg)
            }
            return true
        }
        return false
    }
    private var pathMonitor: NWPathMonitor?

    func startNetworkMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            var parts: [String] = []
            switch path.status {
            case .satisfied: parts.append("已连接")
            case .unsatisfied: parts.append("未连接")
            case .requiresConnection: parts.append("需要连接")
            @unknown default: parts.append("未知")
            }
            if path.usesInterfaceType(.wifi) { parts.append("Wi-Fi") }
            if path.usesInterfaceType(.wiredEthernet) { parts.append("有线") }
            if path.usesInterfaceType(.cellular) { parts.append("蜂窝") }
            if path.isExpensive { parts.append("⚠️ 按流量计费(expensive)") }
            if path.isConstrained { parts.append("⚠️ 低数据模式(constrained)") }
            let text = parts.joined(separator: " · ")
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                let changed = text != self.networkText
                self.networkText = text
                if changed {
                    self.log(expensive || constrained ? .warn : .info, "Net", "网络状态：\(text)")
                    if expensive || constrained {
                        self.log(.warn, "Net", "当前网络被系统标记为“按流量计费/低数据模式”（例如连的是 iPhone 个人热点，或 Wi-Fi 开了低数据模式）。系统的语音模型这类后台大文件下载，在这种网络下可能会被推迟或暂停。")
                    }
                }
            }
        }
        m.start(queue: DispatchQueue(label: "net.monitor"))
        pathMonitor = m
    }

    /// 重启系统资源下载服务（mobileassetd），会弹出管理员密码框；launchd 会自动重新拉起
    func restartAssetService() {
        log(.info, "Service", "请求重启系统下载服务 mobileassetd（需要管理员密码）…")
        Task {
            let script = "do shell script \"/usr/bin/killall mobileassetd; /usr/bin/killall -m 'com.apple.MobileAsset.DownloadService.*' 2>/dev/null; /usr/bin/killall localspeechrecognition 2>/dev/null; exit 0\" with administrator privileges"
            let r = await Task.detached { runCommand("/usr/bin/osascript", ["-e", script], timeout: 120) }.value
            if r.status == 0 {
                self.log(.info, "Service", "已重启下载服务。请等待 10 秒后再次点击「下载」。")
            } else {
                self.log(.warn, "Service", "重启下载服务未完成（退出码 \(r.status)）：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self.refresh(quiet: true)
        }
    }

    func cancel(_ id: String) {
        progresses[id]?.cancel()
        downloadTasks[id]?.cancel()
        log(.warn, "Download", "已请求取消 \(displayName(id)) [\(id)]")
    }

    func isTracking(_ id: String) -> Bool { downloadTasks[id] != nil }

    func release(_ locale: Locale) {
        Task {
            let ok = await AssetInventory.release(reservedLocale: locale)
            log(ok ? .info : .warn, "Reserve", "释放预留 \(displayName(localeKey(locale))) [\(localeKey(locale))]：\(ok ? "成功" : "失败")")
            await refresh(quiet: true)
        }
    }

    // MARK: 系统日志
    func fetchSystemLogs() async {
        guard !isFetchingLogs else { return }
        isFetchingLogs = true
        defer { isFetchingLogs = false }
        let startDate = lastLogFetch.addingTimeInterval(-2)
        let now = Date()
        let startStr = logStartFormatter.string(from: startDate)
        let pred = systemLogPredicate
        let res = await Task.detached {
            runCommand("/usr/bin/log", ["show", "--style", "compact", "--info", "--start", startStr, "--predicate", pred], timeout: 90)
        }.value
        lastLogFetch = now
        if res.status != 0 {
            log(.warn, "System", "读取系统日志失败（退出码 \(res.status)）：\(String(res.output.prefix(600)))")
            return
        }
        // 合并多行日志：不以日期开头的行属于上一条
        var lines: [String] = []
        for raw in res.output.split(separator: "\n").map(String.init) {
            if raw.hasPrefix("Filtering the log") || raw.hasPrefix("Timestamp") { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if raw.hasPrefix("20") && raw.count > 23 && raw.dropFirst(4).first == "-" {
                lines.append(raw)
            } else if !lines.isEmpty {
                if lines[lines.count - 1].count < 4000 { lines[lines.count - 1] += " ⏎ " + trimmed }
            }
        }
        if lines.count > 8000 { lines = Array(lines.suffix(8000)) }
        if seenLines.count > 30000 { seenLines.removeAll() }
        var added = 0
        var errs = 0
        var folded = 0
        var noise = 0
        // 本轮内按“去掉时间/线程/地址后的内容”分组，重复的折叠成一条
        var order: [String] = []
        var firstLine: [String: String] = [:]
        var counts: [String: Int] = [:]
        for line in lines where !seenLines.contains(line) {
            seenLines.insert(line)
            trackSpeechUsage(line)
            if consumeAssetLine(line) { continue }
            let isOwn = line.contains(" LiveCaptionsDoctor[")
            let lv0 = logLevel(forSystemLine: line)
            // 本工具自己进程的普通日志（XPC 连接等）没有诊断价值，跳过
            if isOwn && lv0 == .info { continue }
            let key = normalizeLogLine(line)
            if counts[key] == nil {
                order.append(key)
                firstLine[key] = line
                counts[key] = 1
            } else {
                counts[key]! += 1
            }
        }
        for key in order {
            guard let line = firstLine[key] else { continue }
            let n = counts[key] ?? 1
            let prev = seenPatterns[key] ?? 0
            seenPatterns[key] = prev + n
            var lv = logLevel(forSystemLine: line)
            var text = line
            if isKnownNoise(line) {
                lv = .info
                noise += n
                text = "〔已知噪音：本工具探测语言时触发，可忽略〕" + line
            }
            if prev > 0 {
                // 之前已经出现过的同类日志，不再重复显示
                folded += n
                continue
            }
            if n > 1 {
                text += "   〔本轮重复 ×\(n)〕"
                folded += n - 1
            }
            if lv == .error { errs += 1 }
            logs.append(LogEntry(time: Date(), level: lv, source: "System", text: text))
            added += 1
        }
        foldedCount += folded
        noiseCount += noise
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
        if added > 0 || folded > 0 {
            log(.info, "System", "系统日志：新增 \(added) 条（错误 \(errs)），折叠重复 \(folded) 条，已知噪音 \(noise) 条")
        }
    }

    // MARK: 深度扫描
    func deepScan() {
        log(.info, "Scan", "开始深度扫描…")
        Task {
            let out: [String] = await Task.detached {
                var out: [String] = []
                let fm = FileManager.default
                let keywords = ["speech", "asr", "dictation", "transcri", "caption", "siri"]
                for base in ["/System/Library/AssetsV2", "/private/var/MobileAsset/AssetsV2"] {
                    do {
                        let items = try fm.contentsOfDirectory(atPath: base)
                        let hits = items.filter { n in keywords.contains { n.lowercased().contains($0) } }
                        out.append("\(base)：共 \(items.count) 类资源，语音相关 \(hits.count) 类")
                        for h in hits.sorted() {
                            let dir = base + "/" + h
                            let sub = (try? fm.contentsOfDirectory(atPath: dir))?.filter { !$0.hasPrefix(".") } ?? []
                            out.append("  • \(h)（\(sub.count) 项）")
                            for a in sub.sorted().prefix(10) {
                                let full = dir + "/" + a
                                var isDir: ObjCBool = false
                                fm.fileExists(atPath: full, isDirectory: &isDir)
                                if !isDir.boolValue { continue }
                                let du = runCommand("/usr/bin/du", ["-sk", full], timeout: 30).output
                                let kb = Int64(du.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                                let inner = ((try? fm.contentsOfDirectory(atPath: full)) ?? []).filter { $0.hasSuffix(".asset") }.sorted()
                                out.append("      - \(a)：\(inner.count) 个资源，共 " + formatMB(kb * 1024))
                                // 逐个读取资源的 Info.plist（UAF 资源在 <hash>.asset/Info.plist）
                                for asset in inner.prefix(25) {
                                    let ap = full + "/" + asset
                                    let adu = runCommand("/usr/bin/du", ["-sk", ap], timeout: 15).output
                                    let akb = Int64(adu.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                                    out.append("          · " + describeAsset(ap) + "  [" + formatMB(akb * 1024) + "]")
                                }
                                if inner.count > 25 { out.append("          · …还有 \(inner.count - 25) 个") }
                            }
                        }
                    } catch {
                        out.append("\(base)：无法读取（\(error.localizedDescription)）")
                    }
                }
                let ps = runCommand("/bin/ps", ["-axo", "pid=,comm="], timeout: 5).output
                let speechProcs = ps.split(separator: "\n").map(String.init).filter { l in
                    let low = l.lowercased()
                    return (low.contains("caption") || low.contains("transcri") || low.contains("speech") || low.contains("asr") || low.contains("dictation")) && !low.contains("livecaptionsdoctor")
                }
                out.append("语音/字幕相关进程：" + (speechProcs.isEmpty ? "无" : ""))
                for l in speechProcs { out.append("  • " + l.trimmingCharacters(in: .whitespaces)) }
                for word in ["LiveCaption", "Live Captions", "LiveTranscription"] {
                    let r = runCommand("/usr/bin/defaults", ["find", word], timeout: 20)
                    var domains: [String] = []
                    for l in r.output.split(separator: "\n") {
                        if let m = firstMatch("Found (\\d+) keys? in domain '([^']+)'", in: String(l)) {
                            let d = m[2]
                            // 跳过：访达最近文件夹、本工具自己、其他编辑器记录的路径
                            if d == "com.apple.finder" || d.hasPrefix("local.tanaka") || d.contains("macdown") { continue }
                            domains.append(d + "（\(m[1]) 项）")
                        }
                    }
                    out.append("包含 “\(word)” 的偏好设置域：" + (domains.isEmpty ? "无（已忽略访达最近记录和本工具）" : domains.joined(separator: ", ")))
                }
                for domain in ["com.apple.accessibility.LiveCaptions", "com.apple.LiveCaptions", "com.apple.accessibility.livecaptions", "com.apple.LiveTranscriptionAgent"] {
                    let r = runCommand("/usr/bin/defaults", ["read", domain], timeout: 5)
                    if r.status == 0 {
                        out.append("偏好设置 \(domain)：\n\(String(r.output.prefix(3000)))")
                    } else {
                        out.append("偏好设置 \(domain)：不存在")
                    }
                }
                return out
            }.value
            for l in out { log(.info, "Scan", l) }
            log(.info, "Scan", "深度扫描完成")
        }
    }

    // MARK: 报告
    func buildReport(errorsOnly: Bool, fullLog: Bool = false) -> String {
        var s = "# 实时字幕语言诊断报告\n生成时间：\(Date().formatted(date: .numeric, time: .standard))\n\n## 环境\n"
        s += envLines.map { "- " + $0 }.joined(separator: "\n")
        s += "\n- 网络：" + networkText
        s += "\n- 本工具预留语言：\(reservedLocales.count)/\(maxReserved)（\(reservedLocales.map(localeKey).joined(separator: ", "))）\n"

        let c = Dictionary(grouping: rows, by: { $0.overall }).mapValues(\.count)
        s += "\n说明：实时字幕只需要“转写”模型；“系统已有”= 模型已在系统中（由系统/实时字幕自己下载），本工具未预留\n"
        s += "\n## 汇总\n共 \(rows.count) 种；" + Overall.allCases.map { "\($0.rawValue) \(c[$0] ?? 0)" }.joined(separator: "，") + "\n"

        let listRows = errorsOnly ? rows.filter { $0.overall != .ready && $0.overall != .unsupported } : rows.filter { $0.overall != .unsupported }
        s += "\n## 语言明细（\(errorsOnly ? "未就绪" : "全部支持的语言")）\n"
        for r in listRows {
            var legacy = "—"
            if let lo = r.legacyOnDevice { legacy = lo ? "是" : "否" }
            var item = "- " + r.name + " [" + r.id + "]：" + r.overall.rawValue
            item += "｜转写 " + r.speech.rawValue
            item += "｜听写 " + r.dictation.rawValue
            item += "｜传统离线 " + legacy
            if r.reserved { item += "｜已预留" }
            if let e = r.lastError { item += "｜错误：" + e }
            s += item + "\n"
        }

        s += "\n- 系统日志已折叠重复 \(foldedCount) 条，已知噪音 \(noiseCount) 条（No asset found … siri.asr.assistant 等）\n"
        s += "\n## 实时字幕当前状态\n"
        s += "- 进程：" + (lastProcs.contains("Live Captions") ? "运行中" : "未运行") + "\n"
        s += "- 语言：" + (lcLocale.isEmpty ? "未知" : lcLocale + "（" + displayName(lcLocale) + "）") + "｜状态：" + lcState
        if let p = lcProgress { s += "｜模型下载 \(p)%" }
        if let t = lcLastCaption { s += "｜最近字幕 " + timeFormatter.string(from: t) }
        s += "｜累计字幕 \(lcCaptionCount) 条\n"
        if !modelLines.isEmpty {
            s += "\n## 转写模型版本 / 完整性\n"
            s += modelLines.map { "- " + $0 }.joined(separator: "\n") + "\n"
        } else if !asrDescriptors.isEmpty {
            s += "\n## 转写模型（来自系统日志）\n"
            for (k, v) in asrDescriptors.sorted(by: { $0.key < $1.key }) {
                s += "- [\(k)] 版本 \(v.0)，ID \(v.1.prefix(10))，安装 \(formatMB(v.3))\n"
            }
        }
        if !updateChecks.isEmpty {
            s += "\n## 系统自动检查更新（最近一次）\n"
            for (k, v) in updateChecks.sorted(by: { $0.key < $1.key }) {
                s += "- \(k)：\(v.1)（\(timeFormatter.string(from: v.0))）\n"
            }
        }
        if !sysJobs.isEmpty {
            s += "\n## 系统下载任务（mobileassetd）\n"
            for j in sysJobs.values.sorted(by: { $0.name < $1.name }) {
                var t = "- \(j.name)：\(formatMB(j.written))/\(formatMB(j.expected))（\(Int(j.fraction * 100))%）"
                if j.speed > 0 { t += String(format: "，%.2f MB/s", j.speed / 1_048_576) }
                if j.remaining > 0 { t += "，剩余约 " + formatDuration(j.remaining) }
                t += j.finished ? "，已完成" : (j.stalled ? "，⚠️ 卡住" : "")
                if j.updated != .distantPast { t += "，更新于 " + timeFormatter.string(from: j.updated) }
                s += t + "\n"
            }
        }

        // 1) 本工具自己的日志（下载过程、状态变化、网络等）——最重要，全部保留
        let toolLogs = logs.filter { $0.source != "System" }
        s += "\n## 工具日志（\(toolLogs.count) 条\(fullLog ? "" : "，显示最后 400 条")）\n```\n"
        s += (fullLog ? toolLogs : Array(toolLogs.suffix(400))).map(line).joined(separator: "\n")
        s += "\n```\n"

        // 2) 系统日志中的错误
        let errs = logs.filter { $0.level == .error && $0.source == "System" }
        s += "\n## 系统错误（\(errs.count) 条，显示最后 120 条）\n```\n"
        s += errs.suffix(120).map(line).joined(separator: "\n")
        s += "\n```\n"

        // 3) 系统日志中的警告（下载卡住、网络问题等）
        let warns = logs.filter { $0.level == .warn && $0.source == "System" }
        s += "\n## 系统警告（\(warns.count) 条，显示最后 150 条）\n```\n"
        s += warns.suffix(150).map(line).joined(separator: "\n")
        s += "\n```\n"

        // 4) 其他系统日志
        if !errorsOnly {
            let infos = logs.filter { $0.level == .info && $0.source == "System" }
            let n = fullLog ? infos.count : min(infos.count, 150)
            s += "\n## 其他系统日志（共 \(infos.count) 条，显示最后 \(n) 条）\n```\n"
            s += infos.suffix(n).map(line).joined(separator: "\n")
            s += "\n```\n"
        }
        return s
    }

    func line(_ e: LogEntry) -> String {
        "\(timeFormatter.string(from: e.time)) [\(e.level.rawValue)] [\(e.source)] \(e.text)"
    }

    func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func saveReportToDesktop() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/LiveCaptionsDoctor-\(f.string(from: Date())).txt")
        do {
            try buildReport(errorsOnly: false, fullLog: true).write(to: url, atomically: true, encoding: .utf8)
            log(.info, "App", "完整报告已保存：\(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log(.error, "App", "保存报告失败：\(describeError(error))")
        }
    }

    func openLiveCaptionsSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?LiveCaptions") {
            NSWorkspace.shared.open(u)
            log(.info, "App", "已打开 系统设置 > 辅助功能")
        }
    }
}

// MARK: - 界面

enum RowFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case ready = "已就绪"
    case notReady = "未就绪 / 下载中"
    case unsupported = "不支持"
    var id: String { rawValue }
}

@MainActor
final class UIState: ObservableObject {
    @Published var filter: RowFilter = .all
    @Published var search: String = ""
    @Published var problemsOnly: Bool = false
    @Published var flash: String? = nil
    @Published var showReserved: Bool = false
}

struct ContentView: View {
    @EnvironmentObject var model: DoctorModel
    // 不使用 @State（macOS 27 SDK 中 @State 是宏，只装命令行工具时找不到宏插件）
    @StateObject private var ui = UIState()

    var filteredRows: [LangRow] {
        model.rows.filter { r in
            let f: Bool
            switch ui.filter {
            case .all: f = true
            case .ready: f = r.overall == .ready
            case .notReady: f = (r.overall != .ready && r.overall != .unsupported)
            case .unsupported: f = r.overall == .unsupported
            }
            let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
            return f && (q.isEmpty || r.name.lowercased().contains(q) || r.id.lowercased().contains(q))
        }
        .sorted { a, b in
            let pa = isPreferred(a), pb = isPreferred(b)
            if pa != pb { return pa }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func isPreferred(_ r: LangRow) -> Bool {
        guard let code = r.locale.language.languageCode?.identifier else { return false }
        return model.preferredLanguageCodes.contains(code)
    }

    var visibleLogs: [LogEntry] {
        ui.problemsOnly ? model.logs.filter { $0.level != .info } : model.logs
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 10) {
                header
                summary
                lcPanel
                if !model.activeSysJobs.isEmpty { sysJobsPanel }
                filterBar
                languageList
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 6)
            .frame(minHeight: 380)

            logPanel
                .frame(minHeight: 230)
        }
        .onAppear { model.start() }
    }

    // 顶部
    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("实时字幕 · 语言模型诊断").font(.title2.bold())
                ForEach(Array(model.envLines.prefix(3).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption).foregroundStyle(.secondary)
                }
                Text("网络：" + model.networkText).font(.caption)
                    .foregroundStyle(model.networkText.contains("⚠️") ? Color.orange : Color.secondary)
                if let t = model.lastRefresh {
                    Text("上次检测：\(t.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Toggle("自动刷新", isOn: $model.autoRefresh).toggleStyle(.switch).controlSize(.small)
                    Button { Task { await model.refresh() } } label: { Label("重新检测", systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing)
                }
                HStack {
                    Button { model.deepScan() } label: { Label("深度扫描", systemImage: "magnifyingglass") }
                    Button { model.requestSpeechAuth() } label: { Label("语音权限", systemImage: "hand.raised") }
                    Button { model.openLiveCaptionsSettings() } label: { Label("打开实时字幕设置", systemImage: "captions.bubble") }
                    Button { model.startLiveCaptionTest() } label: {
                        Label(model.testRemaining > 0 ? "测试中… \(model.testRemaining)s" : "实时字幕测试", systemImage: "waveform")
                    }
                    .disabled(model.testRemaining > 0)
                    .help("90 秒内打开实时字幕并让它识别声音，工具会记录实时字幕实际用了哪些语音模型")
                    Button { model.restartAssetService() } label: { Label("重启下载服务", systemImage: "arrow.triangle.2.circlepath") }
                        .help("重启系统的资源下载服务（mobileassetd），下载卡住时使用，需要管理员密码")
                }
            }
        }
    }

    var summary: some View {
        HStack(spacing: 8) {
            ForEach(Overall.allCases) { o in
                let n = model.rows.filter { $0.overall == o }.count
                HStack(spacing: 5) {
                    Circle().fill(o.color).frame(width: 8, height: 8)
                    Text("\(o.rawValue) \(n)").font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(o.color.opacity(0.13), in: Capsule())
            }
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                ui.showReserved.toggle()
            } label: {
                Text("预留语言 \(model.reservedLocales.count)/\(model.maxReserved)").font(.caption)
            }
            .popover(isPresented: $ui.showReserved) { reservedPopover }
        }
    }

    var lcPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble").foregroundStyle(.secondary)
            Text("实时字幕：").font(.callout.bold())
            if model.lcLocale.isEmpty {
                Text(model.lastProcs.contains("Live Captions") ? "运行中，等待日志…" : "未运行").foregroundStyle(.secondary)
            } else {
                Text("\(displayName(model.lcLocale))  [\(model.lcLocale)]")
                Text(model.lcState)
                    .foregroundStyle(model.lcReady == false ? Color.orange : (model.lcReady == true ? Color.green : Color.secondary))
                if let p = model.lcProgress {
                    ProgressView(value: Double(p), total: 100).frame(width: 120)
                }
                if let t = model.lcLastCaption {
                    Text("最近字幕 \(timeFormatter.string(from: t))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.checkModels() } label: { Label(model.isCheckingModels ? "检查中…" : "模型版本/完整性", systemImage: "checkmark.seal") }
                .controlSize(.small)
                .disabled(model.isCheckingModels)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    var sysJobsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("系统下载任务（来自系统日志，每 8 秒更新）").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.activeSysJobs) { j in
                HStack(spacing: 10) {
                    Text(j.name).font(.caption).frame(width: 240, alignment: .leading).lineLimit(1)
                    ProgressView(value: j.fraction).frame(width: 220)
                    Text(sysJobLine(j)).font(.caption.monospacedDigit())
                        .foregroundStyle(j.stalled ? Color.orange : Color.secondary)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    func sysJobLine(_ j: SysJob) -> String {
        var t = formatMB(j.written) + " / " + formatMB(j.expected) + "  (\(Int(j.fraction * 100))%)"
        if j.speed > 0 { t += String(format: "  ·  %.2f MB/s", j.speed / 1_048_576) }
        if j.remaining > 0 { t += "  ·  剩余约 " + formatDuration(j.remaining) }
        if j.stalled { t += "  ·  ⚠️ 卡住" }
        return t
    }

    var reservedPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本工具预留的语言").font(.headline)
            Text("系统对每个 App 可预留的语言数量有上限。名额满了会导致下载失败。\n释放后系统可能在空间紧张时删除该语言模型——正在使用的语言请不要释放。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.reservedLocales.isEmpty {
                Text("（暂无）").foregroundStyle(.secondary)
            }
            ForEach(model.reservedLocales, id: \.identifier) { l in
                HStack {
                    Text("\(displayName(localeKey(l))) [\(localeKey(l))]")
                    Spacer()
                    Button("释放") { model.release(l) }
                }
            }
        }
        .padding()
        .frame(width: 380)
    }

    var filterBar: some View {
        HStack {
            Picker("", selection: $ui.filter) {
                ForEach(RowFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            TextField("搜索语言（名称或代码，如 ja、粤语）", text: $ui.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Spacer()
            Text("⭐ = 系统首选语言").font(.caption).foregroundStyle(.secondary)
        }
    }

    var languageList: some View {
        List {
            HStack(spacing: 12) {
                Text("语言").frame(width: 210, alignment: .leading)
                Text("实时字幕").frame(width: 90, alignment: .leading)
                Text("转写(字幕用)").frame(width: 70, alignment: .leading)
                Text("听写模型").frame(width: 70, alignment: .leading)
                Text("传统离线").frame(width: 60, alignment: .leading)
                Text("进度 / 信息").frame(maxWidth: .infinity, alignment: .leading)
                Text("操作").frame(width: 120, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            ForEach(filteredRows) { row in
                LangRowView(row: row, preferred: isPreferred(row))
            }
            if filteredRows.isEmpty {
                Text(model.isRefreshing ? "正在检测…" : "没有符合条件的语言").foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // 日志
    var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("日志").font(.headline)
                if model.errorCount > 0 {
                    Text("\(model.errorCount) 个错误")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                if model.isFetchingLogs { ProgressView().controlSize(.mini); Text("读取系统日志中…").font(.caption).foregroundStyle(.secondary) }
                if model.foldedCount > 0 || model.noiseCount > 0 {
                    Text("已折叠重复 \(model.foldedCount) · 已知噪音 \(model.noiseCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("自动收集系统日志", isOn: $model.collectSystemLogs).toggleStyle(.checkbox)
                Toggle("只看错误/警告", isOn: $ui.problemsOnly).toggleStyle(.checkbox)
                Spacer()
                if let f = ui.flash { Text(f).font(.caption.bold()).foregroundStyle(.green) }
                Button("立即抓取") { Task { await model.fetchSystemLogs() } }
                Button("清空") { model.clearLogs() }
                Button("保存到桌面") { model.saveReportToDesktop() }
                Button {
                    model.copyToClipboard(model.buildReport(errorsOnly: true))
                    showFlash("✓ 已复制错误摘要")
                } label: { Label("仅复制错误", systemImage: "exclamationmark.triangle") }
                Button {
                    model.copyToClipboard(model.buildReport(errorsOnly: false))
                    showFlash("✓ 已复制完整诊断报告")
                } label: { Label("一键复制诊断报告", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLogs) { e in
                            Text(model.line(e))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: e.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(e.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: model.logs.count) { _, _ in
                    if let last = visibleLogs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
    }

    func color(for l: LogLevel) -> Color {
        switch l {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    func showFlash(_ s: String) {
        let state = ui
        state.flash = s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            state.flash = nil
        }
    }
}

struct LangRowView: View {
    @EnvironmentObject var model: DoctorModel
    let row: LangRow
    let preferred: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text((preferred ? "⭐ " : "") + row.name).font(.body.weight(.medium))
                Text(row.id + (row.reserved ? "  · 已预留" : "") + (model.lcLocale == row.id ? "  · 实时字幕使用中" : "")).font(.caption.monospaced()).foregroundStyle(model.lcLocale == row.id ? Color.blue : Color.secondary)
            }
            .frame(width: 210, alignment: .leading)

            Text(row.overall.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(row.overall.color.opacity(0.15), in: Capsule())
                .foregroundStyle(row.overall.color)
                .frame(width: 90, alignment: .leading)

            Text(row.speech.rawValue).font(.callout).foregroundStyle(row.speech.color).frame(width: 70, alignment: .leading)
            Text(row.dictation.rawValue).font(.callout).foregroundStyle(row.dictation.color).frame(width: 70, alignment: .leading)
            Text(row.legacyOnDevice.map { $0 ? "是" : "否" } ?? "—").font(.callout).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let p = row.progress {
                    ProgressView(value: p)
                    Text(row.progressText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if row.overall == .downloading {
                    ProgressView().progressViewStyle(.linear)
                    Text("系统正在下载（点“跟踪进度”显示百分比）").font(.caption2).foregroundStyle(.secondary)
                } else if let e = row.lastError {
                    Text("❌ " + e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else if row.overall == .partial {
                    Text("部分模型缺失，实时字幕可能无法使用").font(.caption2).foregroundStyle(.orange)
                } else if row.overall == .needsDownload {
                    Text("实时字幕里能选，但模型没下载；选了会先在后台下载，下载完之前不出字幕").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action.frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder var action: some View {
        switch row.overall {
        case .ready:
            if row.dictationMissing && row.progress == nil {
                Button("+听写") { model.download(row.id, includeDictation: true) }
                    .controlSize(.small)
                    .help("实时字幕不需要听写模型；只有键盘听写需要时才下载")
            } else {
                Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .unsupported:
            Text("—").foregroundStyle(.secondary)
        case .downloading:
            if model.isTracking(row.id) {
                Button("取消") { model.cancel(row.id) }
            } else {
                Button("跟踪进度") { model.download(row.id) }
            }
        case .needsDownload, .partial:
            Button { model.download(row.id) } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate() }
}

@main
struct LiveCaptionsDoctorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = DoctorModel()

    var body: some Scene {
        WindowGroup("实时字幕语言诊断") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 740)
        }
    }
}
