import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

public enum Permission: String, CaseIterable, Identifiable {
    case microphone, accessibility, screenRecording, automation, speechRecognition
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .speechRecognition: return "Speech Recognition"
        }
    }
    public var why: String {
        switch self {
        case .microphone: return "To hear your commands and dictation."
        case .accessibility: return "To click, type and press shortcuts in other apps."
        case .screenRecording: return "Only for the screenshot fallback (\"Looking at the screen…\")."
        case .automation: return "To switch browser tabs in Chrome and Safari."
        case .speechRecognition: return "Only for the on-device “Hey Sirena” while waiting. Also needs Dictation on (System Settings → Keyboard → Dictation)."
        }
    }
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .automation: anchor = "Privacy_Automation"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
    public var isRequired: Bool { self == .microphone || self == .accessibility }
}

public enum PermissionStatus: Equatable { case granted, denied, notDetermined, unknown }

public enum Permissions {
    private static var automationGranted: Bool?

    public static func status(_ p: Permission) -> PermissionStatus {
        switch p {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .automation:
            if let g = automationGranted { return g ? .granted : .denied }
            return .unknown
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    public static var allRequiredGranted: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy { status($0) == .granted }
    }

    /// Triggers the system prompt where possible.
    public static func request(_ p: Permission, completion: @escaping (PermissionStatus) -> Void) {
        switch p {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok ? .granted : .denied) } }
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let ok = AXIsProcessTrustedWithOptions(opts)
            completion(ok ? .granted : .denied)
        case .screenRecording:
            let ok = CGRequestScreenCaptureAccess()
            completion(ok ? .granted : .denied)
        case .speechRecognition:
            LocalWakeWordDetector.requestAuthorization { ok in completion(ok ? .granted : .denied) }
        case .automation:
            DispatchQueue.global().async {
                let ok = BrowserControl.run("tell application \"System Events\" to return name of first process", timeout: 10) != nil
                automationGranted = ok
                DispatchQueue.main.async { completion(ok ? .granted : .denied) }
            }
        }
    }

    public static func noteAutomation(granted: Bool) { automationGranted = granted }

    public static func openSettings(_ p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
    }
}
