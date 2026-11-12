#if os(iOS)
import BackgroundTasks
import JotCore
import JotInbox
import UIKit
import UserNotifications

/// Keeps a phone job going after you leave Jot. iOS 26's continued processing shows its progress in a
/// system pill. If iOS won't start one (or stops it), the job pauses while Jot is closed and the Mac takes
/// it after 5 minutes.
@MainActor
final class BackgroundJob {
    private let id = "com.kezlahd.jot.transcribe.\(UUID().uuidString)"
    private var task: BGContinuedProcessingTask?
    private var fraction = 0.0
    private var done = false

    /// Whether this phone lets background work use the GPU. Without it Whisper runs on the CPU when Jot is closed.
    nonisolated static var gpu: Bool { BGTaskScheduler.supportedResources.contains(.gpu) }

    init(title: String) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                guard let self, !self.done else { task.setTaskCompleted(success: true); return }
                self.attach(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Transcribing", subtitle: title)
        request.strategy = .fail  // if it can't start now, the job just runs while Jot is open
        if Self.gpu { request.requiredResources = .gpu }
        try? BGTaskScheduler.shared.submit(request)
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64(fraction * 100)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.task = nil }
        }
    }

    /// 0…1 across fetching and listening.
    func update(_ fraction: Double, title: String? = nil) {
        self.fraction = max(self.fraction, min(1, fraction))
        task?.progress.completedUnitCount = Int64(self.fraction * 100)
        if let title, let task { task.updateTitle(title, subtitle: task.subtitle) }
    }

    func finish(success: Bool) {
        done = true
        task?.progress.completedUnitCount = 100
        task?.setTaskCompleted(success: success)
        task = nil
    }
}

/// Whisper on the GPU while Jot is open. In the background, iOS refuses GPU work unless the phone
/// supports it for continued processing, so there Whisper runs on the CPU (slower, but it finishes).
final class PhoneWhisper: Transcriber, @unchecked Sendable {
    let engine = "whisper.cpp"
    var modelName: String { gpu.modelName }
    private let gpu: WhisperTranscriber
    private var cpu: WhisperTranscriber?

    init(gpu: WhisperTranscriber) { self.gpu = gpu }

    private func cpuWhisper() throws -> WhisperTranscriber {
        if let cpu { return cpu }
        let w = try WhisperTranscriber(gpu: false)
        cpu = w
        return w
    }

    private static func inBackground() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .background } && !BackgroundJob.gpu
    }

    func transcribe(file: URL, samples: @Sendable () async throws -> [Float], language: String?,
                    progress: (@Sendable (Double) -> Void)?) async throws -> (segments: [Read.Segment], language: String) {
        if await Self.inBackground() {
            return try await cpuWhisper().transcribe(file: file, samples: samples, language: language, progress: progress)
        }
        do {
            return try await gpu.transcribe(file: file, samples: samples, language: language, progress: progress)
        } catch {
            // Closed partway through: iOS stopped the GPU work. Finish on the CPU.
            guard await Self.inBackground() else { throw error }
            return try await cpuWhisper().transcribe(file: file, samples: samples, language: language, progress: progress)
        }
    }
}

/// Banners when a job finishes while Jot isn't on screen. Jobs the Mac runs arrive as pushes (App/Push.swift);
/// jobs this phone runs are posted here.
enum Notify {
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func post(_ title: String, _ body: String, readID: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "jot"
        if let readID { content.userInfo = ["read": readID] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: readID ?? UUID().uuidString, content: content, trigger: nil))
    }

    /// Whether APNs should go through the sandbox: builds installed from Xcode or tools/phone.sh are signed for
    /// development; TestFlight and App Store builds carry no provisioning profile and use production.
    static let sandbox: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #"aps-environment</key>\s*<string>(\w+)"#, options: .regularExpression) else { return false }
        return text[r].hasSuffix("development")
    }()
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var token: String? { didSet { if let token { onToken?(token) } } }
    @MainActor static var onToken: ((String) -> Void)?
    @MainActor static var pendingRead: String? { didSet { if let pendingRead { onOpen?(pendingRead) } } }
    @MainActor static var onOpen: ((String) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        CloudShared.pushDevice = (hex, Notify.sandbox)  // the share extension hands it to the cloud runner
        Task { @MainActor in AppDelegate.token = hex }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// Jot is open: the list already shows it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = (info["read"] ?? info["request"]) as? String else { return }
        await MainActor.run { AppDelegate.pendingRead = id }
    }
}

/// Where the Mac finds this phone's push token: Devices/<id>.json in the shared library.
struct PhoneDevice: Codable, Equatable {
    var token: String
    var sandbox: Bool
    var name: String

    @MainActor
    static func save(token: String, in library: Library) {
        let folder = library.root.appending(path: "Devices", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
        let file = folder.appending(path: "\(id).json")
        let device = PhoneDevice(token: token, sandbox: Notify.sandbox, name: UIDevice.current.name)
        if let old = try? Data(contentsOf: file), (try? JSONDecoder().decode(PhoneDevice.self, from: old)) == device { return }
        try? JSONEncoder().encode(device).write(to: file, options: .atomic)
    }
}
#endif
