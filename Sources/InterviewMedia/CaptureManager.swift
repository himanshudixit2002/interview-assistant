import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import InterviewCore

public enum CaptureSourceKind: String, Codable, Sendable { case window, application }

/// A selectable capture source. Titles are shown to the user but never logged (plan §14.4).
public struct CaptureSourceDescriptor: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var kind: CaptureSourceKind
    public var title: String
    public var applicationName: String
    public var bundleIdentifier: String
    public var windowID: UInt32?
    public var processID: Int32
    public var width: Int
    public var height: Int
    public var isOnScreen: Bool
    public var displayLabel: String { kind == .window ? "\(applicationName) — \(title.isEmpty ? "untitled" : title)" : applicationName }
}

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied, windowGone, captureFailed(String)
    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required"
        case .windowGone: return "the selected window is no longer available"
        case .captureFailed(let s): return "capture failed: \(s)"
        }
    }
}

/// Source selection and single-window capture (F25, F27, F33). Never captures a whole display.
public final class CaptureManager: @unchecked Sendable {
    public init() {}

    public static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt once; returns the current state afterwards.
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static let meetingBundlePrefixes = ["us.zoom", "com.microsoft.teams", "com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "org.mozilla.firefox", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.cisco.webex", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.FaceTime", "com.skype", "com.apple.QuickTimePlayerX"]

    /// Running applications without any permission (NSWorkspace). Meeting and browser apps sort first.
    public static func runningApplications() -> [CaptureSourceDescriptor] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app -> CaptureSourceDescriptor? in
            guard app.activationPolicy == .regular, app.processIdentifier != own, let name = app.localizedName, !name.isEmpty else { return nil }
            return CaptureSourceDescriptor(id: "app:\(app.processIdentifier)", kind: .application, title: "", applicationName: name, bundleIdentifier: app.bundleIdentifier ?? "", windowID: nil, processID: app.processIdentifier, width: 0, height: 0, isOnScreen: !app.isHidden)
        }.sorted { a, b in
            let ma = meetingBundlePrefixes.contains { a.bundleIdentifier.hasPrefix($0) }, mb = meetingBundlePrefixes.contains { b.bundleIdentifier.hasPrefix($0) }
            if ma != mb { return ma }
            return a.applicationName.localizedCaseInsensitiveCompare(b.applicationName) == .orderedAscending
        }
    }

    /// On-screen windows via the window server. Titles are only available once Screen Recording is granted.
    public static func windowsViaWindowList() -> [CaptureSourceDescriptor] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier ?? "") })
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let number = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != own, let owner = w[kCGWindowOwnerName as String] as? String,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any], let width = bounds["Width"] as? Int, let height = bounds["Height"] as? Int,
                  width >= 200, height >= 120 else { return nil }
            return CaptureSourceDescriptor(id: "window:\(number)", kind: .window, title: (w[kCGWindowName as String] as? String) ?? "", applicationName: owner, bundleIdentifier: apps[pid] ?? "", windowID: number, processID: pid, width: width, height: height, isOnScreen: true)
        }.sorted { ($0.applicationName, $0.title) < ($1.applicationName, $1.title) }
    }

    public func availableWindows() async throws -> [CaptureSourceDescriptor] {
        let content = try await content(onScreenOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.frame.width >= 200, w.frame.height >= 120, let app = w.owningApplication, app.processID != ownPID else { return nil }
            return CaptureSourceDescriptor(id: "window:\(w.windowID)", kind: .window, title: w.title ?? "", applicationName: app.applicationName, bundleIdentifier: app.bundleIdentifier, windowID: w.windowID, processID: app.processID, width: Int(w.frame.width), height: Int(w.frame.height), isOnScreen: w.isOnScreen)
        }.sorted { ($0.isOnScreen ? 0 : 1, $0.applicationName, $0.title) < ($1.isOnScreen ? 0 : 1, $1.applicationName, $1.title) }
    }

    public func availableApplications() async throws -> [CaptureSourceDescriptor] {
        let content = try await content(onScreenOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen: Set<Int32> = []
        return content.applications.compactMap { app in
            guard app.processID != ownPID, !app.applicationName.isEmpty, seen.insert(app.processID).inserted else { return nil }
            return CaptureSourceDescriptor(id: "app:\(app.processID)", kind: .application, title: "", applicationName: app.applicationName, bundleIdentifier: app.bundleIdentifier, windowID: nil, processID: app.processID, width: 0, height: 0, isOnScreen: true)
        }.sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
    }

    public struct WindowState: Sendable, Equatable { public let exists: Bool; public let onScreen: Bool; public let title: String }

    public func windowState(id: UInt32) async -> WindowState {
        guard let content = try? await content(onScreenOnly: false), let w = content.windows.first(where: { $0.windowID == id }) else {
            return WindowState(exists: false, onScreen: false, title: "")
        }
        return WindowState(exists: true, onScreen: w.isOnScreen, title: w.title ?? "")
    }

    public struct Capture: @unchecked Sendable { public let image: CGImage; public let scale: CGFloat; public let durationMs: Double }

    /// Captures one window by identity; `cropTopPoints` excludes window chrome (region capture).
    public func captureWindow(id: UInt32, cropTopPoints: CGFloat = 0) async throws -> Capture {
        guard Self.screenRecordingGranted() else { throw CaptureError.permissionDenied }
        let content = try await content(onScreenOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        let width = filter.contentRect.width
        let height = max(1, filter.contentRect.height - cropTopPoints)
        config.width = Int(width * scale)
        config.height = Int(height * scale)
        if cropTopPoints > 0 { config.sourceRect = CGRect(x: 0, y: cropTopPoints, width: width, height: height) }
        let start = DispatchTime.now()
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            return Capture(image: image, scale: scale, durationMs: ms)
        } catch {
            throw CaptureError.captureFailed("\(error)")
        }
    }

    private func content(onScreenOnly: Bool) async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly) }
        catch { throw Self.screenRecordingGranted() ? CaptureError.captureFailed("\(error)") : CaptureError.permissionDenied }
    }
}
