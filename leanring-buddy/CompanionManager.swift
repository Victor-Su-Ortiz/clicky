//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Pointing Tour State

    /// One stop on a pointing tour, pre-resolved to global AppKit coordinates.
    struct PointingTourStop {
        let screenLocation: CGPoint
        let displayFrame: CGRect
        /// Bubble text shown at this stop (the tag's label, or the onboarding
        /// demo's comment). Nil makes the overlay use a random pointer phrase.
        let bubbleText: String?
    }

    /// What the overlay should do after a stop's dwell completes.
    enum PointingTourAdvanceResult {
        /// The next stop was published — the onChange observer on the correct
        /// screen starts the next leg; the calling view must NOT fly home.
        case advancedToNextStop
        /// No stops remain — the calling view flies back to the user's cursor.
        case tourFinished
    }

    /// Tour stops not yet visited (the currently published stop is excluded).
    private var pendingPointingTourStops: [PointingTourStop] = []

    /// Monotonic token identifying the active tour. Bumped on every new tour
    /// and on cancellation so dwell completions from a cancelled tour's leg
    /// can't advance a newer tour — the overlay's asyncAfter dwell closures
    /// can't be invalidated, only ignored.
    private(set) var pointingTourGeneration: Int = 0

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Cursor-adjacent panel that shows a compact "prompt copied to clipboard"
    /// confirmation when the model produces an improvement prompt.
    private let improvementPromptOverlayManager = CompanionResponseOverlayManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary. nonisolated so
    /// transcription providers (which run off the main actor) can build
    /// their endpoint URLs from it.
    nonisolated static let workerBaseURL = "https://clicky-proxy.minimax-together.workers.dev"

    private lazy var miniMaxAPI: MiniMaxAPI = {
        return MiniMaxAPI(proxyURL: "\(Self.workerBaseURL)/chat")
    }()

    private lazy var miniMaxTTSClient: MiniMaxTTSClient = {
        return MiniMaxTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so the model remembers prior exchanges within a session.
    /// Each entry is the user's transcript and the model's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            // Cancel any running pointing tour first — hiding the overlay
            // destroys the views before any of them can clear the published
            // location, which would leave an invisible buddy on re-enable.
            cancelPointingTour()
            overlayWindowManager.hideOverlay()
            improvementPromptOverlayManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// The web project folder Clicky reads source files from and applies
    /// [EDIT:...] fixes to when the user asks it to ("fix it"). Persisted
    /// so the choice survives app restarts.
    @Published private(set) var webProjectFolderURL: URL? = {
        guard let savedFolderPath = UserDefaults.standard.string(forKey: "webProjectFolderPath") else {
            return nil
        }
        // Validate the persisted path — the folder may have been deleted or
        // renamed since last launch, and a stale entry would render the
        // picker as configured while contributing no files.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: savedFolderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: savedFolderPath, isDirectory: true)
    }()

    func setWebProjectFolder(_ folderURL: URL?) {
        webProjectFolderURL = folderURL
        UserDefaults.standard.set(folderURL?.path, forKey: "webProjectFolderPath")
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the MiniMax API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = miniMaxAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Cancel any running pointing tour before showOverlay tears down the
        // overlay views — destroyed views can't clear the published location,
        // which would leave the buddy invisible on the fresh views.
        cancelPointingTour()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Cancel any running pointing tour before showOverlay tears down the
        // overlay views — destroyed views can't clear the published location,
        // which would leave the buddy invisible for the whole replay (and
        // push-to-talk recovery is blocked while the video plays).
        cancelPointingTour()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        // A nil location with queued stops would strand the tour, so clearing
        // the location always ends the tour as well.
        pendingPointingTourStops.removeAll()
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Pointing Tour Control

    /// Begins a pointing tour: publishes the first stop (which triggers the
    /// overlay's flight animation) and queues the remaining stops.
    private func startPointingTour(_ stops: [PointingTourStop]) {
        guard let firstStop = stops.first else { return }
        pointingTourGeneration += 1
        pendingPointingTourStops = Array(stops.dropFirst())
        publishPointingTourStop(firstStop)
    }

    /// Called by BlueCursorView when a stop's dwell completes. The view passes
    /// the tour generation captured when its leg started; a stale generation
    /// (the tour was cancelled or replaced mid-leg) is treated as finished so
    /// the stale leg flies home without touching the newer tour.
    func advancePointingTourAfterDwell(tourGeneration: Int) -> PointingTourAdvanceResult {
        guard tourGeneration == pointingTourGeneration,
              !pendingPointingTourStops.isEmpty else {
            return .tourFinished
        }
        publishPointingTourStop(pendingPointingTourStops.removeFirst())
        return .advancedToNextStop
    }

    /// Sets the bubble text and display frame BEFORE the location — the
    /// overlay's onChange observer keys off the location and reads the
    /// other two properties when it fires.
    private func publishPointingTourStop(_ stop: PointingTourStop) {
        detectedElementBubbleText = stop.bubbleText
        detectedElementDisplayFrame = stop.displayFrame
        detectedElementScreenLocation = stop.screenLocation
    }

    /// Cancels the whole tour: bumps the generation so in-flight dwell
    /// completions can't advance, and clears the published target.
    private func cancelPointingTour() {
        pointingTourGeneration += 1
        clearDetectedElementLocation()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        cancelPointingTour()
        overlayWindowManager.hideOverlay()
        improvementPromptOverlayManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response, TTS, and pointing tour from a
            // previous utterance
            currentResponseTask?.cancel()
            miniMaxTTSClient.stopPlayback()
            cancelPointingTour()
            // The previous turn's improvement prompt is stale once the user speaks again
            improvementPromptOverlayManager.hideOverlay()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToMiniMaxWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a very experienced web designer who lives in the user's menu bar. you've done thousands of design reviews and you can glance at a webpage and immediately see what's hurting it — weak visual hierarchy, cramped or uneven spacing, sloppy typography, muddy color and contrast, vague copy, broken layout. your taste is bold and opinionated: you'd rather rework a whole section than nudge a pixel, and you push every page toward the version a top design studio would ship. the user just spoke to you via push-to-talk and you can see their screen(s), usually a webpage they're building. your spoken reply goes through text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember every critique and every improvement prompt you've already given them.

    every response has up to three parts, always in this exact order:
    1. a short spoken critique — always present.
    2. a detailed improvement prompt wrapped in [PROMPT] and [/PROMPT] — only when the page has real problems to fix. OR, when the user asked you to apply the fixes yourself and you have the project source files, [EDIT:...] blocks instead (never both).
    3. pointing tags — always present, always the very last thing.

    spoken critique rules:
    - two to four short sentences. lead with the biggest problem, then the next most important ones. be direct but warm — a senior designer who wants the work to win, not a critic showing off.
    - all lowercase, casual. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - no abbreviations or symbols that sound weird read aloud. say "for example" not "e.g.". keep exact pixel values and hex codes out of your voice — those belong in the improvement prompt.
    - name the actual things you see — "the hero headline", "those three pricing cards", "the nav links" — so the user knows exactly what you mean.
    - never say "simply" or "just".
    - keep the spoken part short even when a lot is wrong. the deep detail goes in the improvement prompt, not your voice. if the user explicitly asks you to explain something in depth, you can talk longer — but implementation specifics still go in the prompt block.
    - when you include a [PROMPT] block, end your spoken critique by telling the user the full prompt is on their clipboard, ready to paste into their coding agent.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — review that one unless the user says otherwise.
    - if the screen isn't a webpage, say what you see and ask them to bring the page up. don't review a code editor or a terminal as if it were a design.

    pointing at problem areas:
    you have a small blue triangle cursor that can fly to and point at spots on screen. when you critique a page, point at the actual problem areas so the user sees exactly what you mean. point at up to FOUR spots, in the same order you mention them in your critique — worst problem first. each label is a short 1-3 word name of the problem, like "weak headline" or "cramped nav" or "low contrast".

    coordinates use a 0 to 1000 grid laid over the screenshot: (0,0) is the top-left corner of the image and (1000,1000) is the bottom-right corner. x increases rightward, y increases downward. so the center of the screen is 500,500 and something near the top-right corner is around 950,50.

    format: [POINT:x,y:label] where x,y are integers from 0 to 1000 on that grid. if the spot is on the cursor's screen you can omit the screen number. if it's on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2) — without it the cursor points at the wrong place.

    write multiple tags back to back, like [POINT:500,180:weak headline][POINT:820,40:cramped nav]. the cursor visits them in order and shows each label in a little speech bubble. if pointing wouldn't help — a general question, no page on screen, or the page is good and there's nothing to flag — append [POINT:none].

    the improvement prompt ([PROMPT] block):
    when the page has real problems, write a detailed improvement prompt the user will paste into a coding agent like claude code or cursor. wrap it in [PROMPT] and [/PROMPT]. this block is never spoken aloud — software strips it, shows it on screen, and copies it to the user's clipboard automatically — so write it as a finished artifact, not as dialogue.

    inside the block:
    - write TO the coding agent in second-person imperative: "rebuild the hero so...", "replace the ad-hoc font sizes with...". no greeting, no "here's a prompt", no sign-off.
    - be BOLD. propose the page a top studio would ship, not a safer copy of what's there. prefer a few transformative moves — rebuilding a section's layout, a real type scale, a distinctive color system, a hero that actually sells — over many timid value tweaks. a fix that only changes one hex code or a couple of pixels is almost never worth a list slot; if a section is mediocre, redesign it.
    - be specific and actionable. name concrete elements and sections ("the three pricing cards under the 'plans' heading"), give concrete values (font sizes, weights, spacing, hex colors) where you can, and add one short clause of design reasoning per fix so the agent makes good judgment calls ("so the headline clearly dominates the subhead").
    - cover whatever actually matters on this page — visual hierarchy, spacing and alignment, typography, color and contrast, copy, layout — and skip categories that are fine. never pad the list.
    - number the fixes and order them by impact, biggest first.
    - markdown inside the block is fine (a coding agent reads it), but no fluff — every line should be a change. aim for roughly 200 to 350 words.
    - never write [POINT: tags, the markers [PROMPT] or [/PROMPT], or [EDIT:...] blocks and their <<<<<<< SEARCH / ======= / >>>>>>> REPLACE markers inside the block — describe changes in prose for the coding agent. always close the block with [/PROMPT].

    skip the [PROMPT] block entirely when:
    - the user asks a general question that isn't a page review — answer it in speech.
    - the page is genuinely in good shape — say so and don't invent problems.
    - there's no webpage on screen.
    - the user asked you to apply the fixes yourself — use [EDIT:...] blocks instead (see below).

    applying fixes yourself ([EDIT:...] blocks):
    when the user's message includes their project source files AND they ask you to make the changes — "fix it", "apply that", "make those changes", "do it" — edit the code yourself instead of writing a [PROMPT] block. software applies your edits to the real files immediately, so:
    - emit one or more edit blocks in exactly this format:

    [EDIT:relative/path/to/file.html]
    <<<<<<< SEARCH
    the exact lines to find, copied verbatim from the file
    =======
    the replacement lines
    >>>>>>> REPLACE

    - the SEARCH text must be copied EXACTLY from the file content you were given — every space, indent, and line break — and must be unique enough to match only the place you mean. it is matched literally and replaced at its first occurrence.
    - keep each edit surgical (a tag, a rule block, one section). use several small [EDIT] blocks rather than one giant one.
    - a block ends at its >>>>>>> REPLACE line. there is NO [/EDIT] closing tag in this format — never write [/EDIT]. never paste a whole rewritten file as one block; express even a big redesign as a series of search/replace edits, each anchored to exact lines that exist in the file. blocks in any other shape are rejected by the software and nothing gets applied.
    - only edit files that were included in the message, and write each file's relative path exactly as labeled.
    - if you gave the user a [PROMPT] block earlier in this conversation, implement THAT — don't invent a new direction mid-flight.
    - your spoken text should be a quick summary of what you changed, ending by telling the user to reload the page and ask for a re-review.
    - never write an [EDIT] block unless the user asked you to make changes. if they ask you to fix things but their message has no project files, say you couldn't see their project files and suggest checking the project folder setting in clicky's menu bar panel.
    - even if your earlier replies in this conversation used [PROMPT] blocks, that never means the current turn should: when the user asks you to apply the changes, [EDIT] blocks REPLACE the [PROMPT] block entirely. do not write both, and do not tell the user to paste anything into a coding agent — you ARE making the changes.
    - a long file may end with a "[file truncated ...]" marker. you can't see anything past it — never write a SEARCH against that hidden part.
    - after edits you usually have nothing on screen to point at — end with [POINT:none].

    re-reviews ("is it good now?"):
    when the user comes back after applying your prompt, you get a fresh screenshot. compare it against what you asked for — your earlier [PROMPT] blocks are in this conversation. first acknowledge specifically what improved. then call out anything still off or newly broken. if real issues remain, include a fresh [PROMPT] block covering ONLY the remaining and new issues — never repeat fixes that already landed. if the page is genuinely good now, say so plainly and skip the block. don't manufacture nitpicks to seem useful.

    examples:

    user asks "what's wrong with this page?" with their landing page on screen:
    "honestly, the hero isn't selling anything — headline and screenshot are fighting and both are losing. the whole page is washed-out gray on white, and the typography has no spine. i put a full redesign prompt on your clipboard — paste it into your coding agent.
    [PROMPT]
    redesign this landing page. changes ordered by impact:

    1. **rebuild the hero.** one bold statement: 72px tight-tracked weight-800 headline on the left half, the product screenshot angled inside a browser frame on the right, a single high-contrast cta below the headline. cut the subhead to one line and delete the secondary cta — right now nothing on the page leads.
    2. **install a real type scale.** replace the ad-hoc font sizes with a deliberate scale (14/18/24/40/72), weight 700+ for every section heading, body at 18px with relaxed line height — so the page reads top-to-bottom at a glance instead of as a wall of same-sized text.
    3. **give it a color system.** the page is gray-on-white everywhere. darken body text to near-black (#111827), pick ONE saturated accent and reserve it exclusively for ctas and links, and alternate sections between white and a subtly tinted background to create rhythm.
    4. **make the pricing section commit.** three identical white cards say nothing — visually elevate the recommended plan: larger card, accent border, "most popular" tag, and a filled cta while the other two get outline buttons.
    [/PROMPT]
    [POINT:500,200:weak hero][POINT:500,500:flat typography][POINT:500,700:washed-out colors][POINT:500,850:indistinct pricing]"

    user asks "is it good now?" after applying your fixes, hero fixed but spacing still off:
    "the hero is way better — that headline finally leads the page. spacing is still uneven though, the gap above pricing is about half the others. one small prompt on your clipboard.
    [PROMPT]
    one remaining fix on this landing page:

    1. **section rhythm.** normalize vertical padding between all sections to one consistent value (96px desktop, 64px mobile). the gap above the pricing section is still roughly half the gap above features.
    [/PROMPT]
    [POINT:500,660:uneven spacing]"

    user says "fix it" after a review, with their project source files in the message:
    "done — i rebuilt the hero headline and gave the nav real contrast. reload the page and ask me how it looks.
    [EDIT:index.html]
    <<<<<<< SEARCH
        <h1 class="title">Welcome to our product</h1>
    =======
        <h1 class="hero-headline">Ship better pages, faster</h1>
    >>>>>>> REPLACE
    [EDIT:styles.css]
    <<<<<<< SEARCH
    .nav a { color: #b9bdc4; }
    =======
    .nav a { color: #374151; font-weight: 600; }
    >>>>>>> REPLACE
    [POINT:none]"

    user asks "is it good now?" and the page genuinely looks good:
    "yeah, this is solid now. the hierarchy reads top to bottom the way it should, spacing is consistent, and the cta finally pops. ship it. [POINT:none]"

    user asks a general question like "what font pairs well with inter?":
    "inter is a workhorse, so pair it with something that has more personality for headlines — newsreader or fraunces gives you that editorial contrast without clashing. [POINT:none]"

    CRITICAL: every response must end with coordinate tags — one to four [POINT:x,y:label] tags back to back, or a single [POINT:none] — as the very last thing you write, AFTER the [/PROMPT] marker or the last >>>>>>> REPLACE line if you wrote blocks. the order is always: spoken critique, then the optional [PROMPT]...[/PROMPT] block OR [EDIT:...] blocks, then the tags. if you open a [PROMPT] block you MUST close it with [/PROMPT], and every [EDIT] block MUST end with its >>>>>>> REPLACE line, before the tags. never more than four tags, never mix [POINT:none] with coordinate tags, never write anything after the tags, and never skip them. the prompt block, the edit blocks, and the tags are all stripped by software before your words are spoken aloud, so the user never hears them.
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to MiniMax,
    /// and plays the response aloud via MiniMax TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The model's response may include an optional [PROMPT]...[/PROMPT]
    /// improvement prompt — auto-copied to the clipboard and displayed next
    /// to the cursor — and up to four [POINT:x,y:label] tags which start a
    /// pointing tour of the problem areas.
    private func sendTranscriptToMiniMaxWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        miniMaxTTSClient.stopPlayback()
        // The previous turn's improvement prompt is stale once a new turn begins
        improvementPromptOverlayManager.hideOverlay()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Screenshot labels identify each screen. The model reports
                // pointing coordinates on a 0–1000 grid laid over the image,
                // so the labels don't need pixel dimensions.
                let labeledImages = screenCaptures.map { capture in
                    (data: capture.imageData, label: capture.label)
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // When a project folder is configured, its source files ride
                // along with every request so the model can ground its
                // critique in the real markup and emit [EDIT:...] fixes when
                // asked. Conversation history stores only the raw transcript,
                // so the file payload never accumulates across turns. The
                // gather runs off the main actor — walking the project tree
                // would otherwise stall the spinner on every turn.
                let projectFolderURLForRequest = webProjectFolderURL
                let webProjectFiles = await Task.detached(priority: .userInitiated) {
                    Self.gatherWebProjectFiles(projectFolderURL: projectFolderURLForRequest)
                }.value

                guard !Task.isCancelled else { return }

                // Console diagnostics for the "fix it" path: whether [EDIT]
                // fixes are even possible this turn depends entirely on files
                // being attached, and a configured-but-empty folder would
                // otherwise fail silently (the model just falls back to a
                // [PROMPT] block).
                if let configuredProjectFolderURL = projectFolderURLForRequest {
                    if webProjectFiles.isEmpty {
                        print("⚠️ Project folder is set but no source files were gathered — [EDIT] fixes are unavailable this turn: \(configuredProjectFolderURL.path)")
                    } else {
                        print("📁 Attached \(webProjectFiles.count) project file(s) from \(configuredProjectFolderURL.lastPathComponent): \(webProjectFiles.map(\.relativePath).joined(separator: ", "))")
                    }
                } else {
                    print("📁 No project folder configured — [EDIT] fixes are unavailable; review prompts only")
                }

                let projectFilesContextSection: String
                if webProjectFiles.isEmpty {
                    projectFilesContextSection = ""
                } else {
                    let projectFileSections = webProjectFiles.map { projectFile in
                        "project file: \(projectFile.relativePath)\n```\n\(projectFile.contents)\n```"
                    }
                    projectFilesContextSection = "the user's web project source (\(webProjectFiles.count) file\(webProjectFiles.count == 1 ? "" : "s")):\n\n"
                        + projectFileSections.joined(separator: "\n\n")
                        + "\n\n"
                }

                // The model reliably follows the response format when reminded
                // in the current turn, but tends to drop format scaffolding
                // (the [PROMPT]/[EDIT] blocks and [POINT:...] tags) when the
                // instruction only lives in the system prompt. The reminder is
                // chosen by whether project files are ACTUALLY attached —
                // leaving that check to the model proved unreliable: with
                // prompt-first phrasing and a history full of [PROMPT]-shaped
                // responses, it answered "fix it" with another [PROMPT] block
                // instead of [EDIT] blocks. Conversation history stores the
                // raw transcript, so this reminder never accumulates across
                // turns.
                let formatReminder: String
                if webProjectFiles.isEmpty {
                    formatReminder = "\n\n(format reminder: short spoken critique first; if the page needs work, include the full improvement prompt wrapped in [PROMPT]...[/PROMPT]. this message contains NO project source files, so never emit [EDIT:...] blocks — if the user asked you to apply fixes yourself, tell them you couldn't see their project files and to pick the project folder in clicky's menu bar panel. then end with one to four [POINT:x,y:label] tags or a single [POINT:none] as the very last thing — nothing after the tags)"
                } else {
                    formatReminder = "\n\n(format reminder: the user's project source files are included above. if this message asks you to make or apply the changes yourself — 'fix it', 'apply that', 'do it', 'make those changes' — respond with [EDIT:path] search/replace blocks and never with an improvement-prompt block, even if earlier replies in this conversation used one. each block is exactly: [EDIT:path] on its own line, then a line <<<<<<< SEARCH, the exact existing lines copied verbatim from the file, a line =======, the replacement lines, and a line >>>>>>> REPLACE. there is NO [/EDIT] tag and whole-file rewrites are invalid — if an earlier reply in this conversation used any other edit shape, it was malformed and nothing was applied; use this exact format. if it's a review question instead and the page needs work, include the normal [PROMPT]...[/PROMPT] improvement prompt; if the page is fine or it's a general question, no block at all. short spoken critique first, then the blocks, then end with one to four [POINT:x,y:label] tags or a single [POINT:none] as the very last thing — nothing after the tags)"
                }
                let userPromptWithFormatReminder = projectFilesContextSection
                    + transcript
                    + formatReminder

                let (fullResponseText, _) = try await miniMaxAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptWithFormatReminder,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Log the raw tail so missing/malformed [POINT:...] tags are
                // visible in the console without re-instrumenting the app.
                print("🎯 Raw response tail: …\(String(fullResponseText.suffix(160)))")

                // Split the response into spoken critique, optional improvement
                // prompt, and [POINT:...] tags. The prompt block is extracted
                // before point parsing so its content can never trigger pointing.
                let parseResult = Self.parseCompanionResponse(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Route to exactly ONE outcome — edits win over the prompt.
                // The model is told never to emit both; if it does anyway,
                // two pills back-to-back would hide the first and the
                // clipboard would change without acknowledgment. This runs
                // before TTS so the confirmation is on screen while the
                // critique is spoken. The pill totals include blocks the
                // parser dropped as malformed, so it never claims full
                // success when part of the model's output was discarded.
                let attemptedEditBlockCount = parseResult.codeEdits.count + parseResult.droppedEditBlockCount
                if attemptedEditBlockCount > 0 {
                    let editApplicationResult = applyCodeEditsToProjectFiles(parseResult.codeEdits)
                    for failureSummary in editApplicationResult.failureSummaries {
                        print("⚠️ Code edit failed: \(failureSummary)")
                    }
                    if parseResult.droppedEditBlockCount > 0 {
                        print("⚠️ Dropped \(parseResult.droppedEditBlockCount) malformed edit block(s)")
                    }
                    let unappliedCount = attemptedEditBlockCount - editApplicationResult.appliedCount
                    let confirmationMessage: String
                    if editApplicationResult.appliedCount == 0 {
                        confirmationMessage = "couldn't apply the fixes — ask again"
                    } else if unappliedCount == 0 {
                        let fixNoun = editApplicationResult.appliedCount == 1 ? "fix" : "fixes"
                        confirmationMessage = "applied \(editApplicationResult.appliedCount) \(fixNoun) — reload the page"
                    } else {
                        confirmationMessage = "applied \(editApplicationResult.appliedCount) of \(attemptedEditBlockCount) fixes — see Xcode console"
                    }
                    improvementPromptOverlayManager.showConfirmation(message: confirmationMessage)
                    ClickyAnalytics.trackCodeEditsApplied(
                        appliedCount: editApplicationResult.appliedCount,
                        failedCount: unappliedCount
                    )
                } else if let improvementPromptText = parseResult.improvementPromptText {
                    // Auto-copy the coding-agent prompt and show a compact
                    // "copied" confirmation. The prompt text itself is
                    // deliberately not displayed (distracting) — the
                    // clipboard is the artifact.
                    copyImprovementPromptToClipboard(improvementPromptText)
                    improvementPromptOverlayManager.showConfirmation(message: "prompt copied — paste into your coding agent")
                    ClickyAnalytics.trackImprovementPromptGenerated(improvementPrompt: improvementPromptText)
                }

                // Resolve each parsed point to a tour stop with global AppKit
                // coordinates. Per-point screen selection: an explicit :screenN
                // picks that capture, otherwise the cursor screen.
                let resolvedStops: [PointingTourStop] = parseResult.points.compactMap { point in
                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = point.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()
                    guard let targetScreenCapture else { return nil }
                    return PointingTourStop(
                        screenLocation: Self.convertGridPointToGlobalScreenLocation(point.coordinate, on: targetScreenCapture),
                        displayFrame: targetScreenCapture.displayFrame,
                        bubbleText: point.elementLabel
                    )
                }

                // Drop consecutive duplicate locations — SwiftUI's onChange only
                // fires when the value actually changes, so publishing the same
                // location twice in a row would stall the tour on that stop.
                var tourStops: [PointingTourStop] = []
                for stop in resolvedStops where tourStops.last?.screenLocation != stop.screenLocation {
                    tourStops.append(stop)
                }

                if !tourStops.isEmpty {
                    // Switch to idle BEFORE starting the tour so the triangle
                    // becomes visible and can fly to the first target. Without
                    // this, the spinner hides the triangle and the flight
                    // animation is invisible.
                    voiceState = .idle
                    for point in parseResult.points {
                        ClickyAnalytics.trackElementPointed(elementLabel: point.elementLabel)
                    }
                    startPointingTour(tourStops)
                    print("🎯 Pointing tour: \(tourStops.count) stop(s)")
                } else {
                    print("🎯 Element pointing: no elements")
                }

                // Save this exchange to conversation history WITH its [PROMPT]
                // block and [POINT:...] tags. History entries act as in-context
                // examples: when past replies show stripped tags, the model
                // stops emitting them in new replies (observed: tags vanish
                // from turn 3 onward). Keeping the raw block also lets
                // re-review turns compare the page against what was previously
                // asked for. Responses that arrived without any tag get a
                // synthetic [POINT:none] appended so every history entry
                // demonstrates the required format; no such backfill for the
                // prompt block because it is optional by design.
                //
                // EXCEPTION: when any [EDIT] block was dropped as malformed,
                // the raw response demonstrates a BROKEN edit grammar (e.g.
                // a [/EDIT]-terminated whole-file rewrite, which the parser
                // rejects). Stored verbatim it becomes an in-context example
                // that teaches the model to repeat the bad format on the next
                // fix-it turn — measured: with a malformed example in history
                // the model reproduced the bad shape 3/3 times DESPITE a
                // reminder explicitly forbidding it, versus correct format 2/2
                // with clean history. In-context examples beat instructions,
                // so the bad shape must never re-enter the context. The
                // appended note keeps the entry truthful — without it the
                // spoken text ("done — i rebuilt...") would claim changes that
                // never landed, and the model would skip redoing them.
                let assistantResponseForHistory: String
                if parseResult.droppedEditBlockCount > 0 {
                    assistantResponseForHistory = spokenText
                        + "\n(note: the edit blocks in this reply were malformed, so NONE of them were applied to the files — the changes described above did not happen and still need to be made) [POINT:none]"
                } else {
                    assistantResponseForHistory = fullResponseText.contains("[POINT:")
                        ? fullResponseText
                        : fullResponseText + " [POINT:none]"
                }
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: assistantResponseForHistory
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await miniMaxTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ MiniMax TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while miniMaxTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// MiniMax TTS is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Copies the improvement prompt to the system clipboard so the user can
    /// paste it straight into their coding agent. clearContents() is required
    /// before setString — NSPasteboard ignores writes to a stale change count.
    private func copyImprovementPromptToClipboard(_ improvementPromptText: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(improvementPromptText, forType: .string)
    }

    // MARK: - Web Project Files

    /// One source file from the user's web project, sent to the model so it
    /// can critique the markup and emit [EDIT:...] fixes against it.
    struct WebProjectFile {
        let relativePath: String
        let contents: String
    }

    /// File extensions included when sending the project's source to the model.
    nonisolated private static let includedWebProjectFileExtensions: Set<String> = [
        "html", "htm", "css", "js", "mjs", "jsx", "tsx", "ts", "vue", "svelte"
    ]
    /// Directory names that never contain hand-written page source.
    nonisolated private static let excludedWebProjectDirectoryNames: Set<String> = [
        "node_modules", "dist", "build", "out", ".next", "vendor", ".git"
    ]
    nonisolated private static let maximumWebProjectFileCount = 24
    nonisolated private static let maximumCharactersPerWebProjectFile = 48_000
    nonisolated private static let maximumTotalWebProjectCharacters = 240_000
    /// Files larger than this many bytes are never read at all — at that
    /// size they're generated bundles, not hand-written page source.
    nonisolated private static let maximumWebProjectFileBytes = 1_000_000
    /// Appended to a file that had to be cut at the character cap, so the
    /// model can see the file exists but is incomplete (the system prompt
    /// tells it never to target text past this marker).
    nonisolated static let webProjectFileTruncationMarker = "\n... [file truncated — the rest was too long to include]"

    /// Reads the project folder's source files, shallowest paths first so the
    /// entry page (index.html) lands early. Bounded by file-count and
    /// character caps so a large project can't blow up the request; files
    /// over the character cap are truncated with a visible marker rather
    /// than silently omitted. nonisolated static so it can run OFF the main
    /// actor via Task.detached — walking a project tree and reading files is
    /// real work that would otherwise stall the UI on every push-to-talk turn.
    nonisolated private static func gatherWebProjectFiles(projectFolderURL: URL?) -> [WebProjectFile] {
        guard let projectFolderURL else { return [] }
        let fileManager = FileManager.default
        guard let directoryEnumerator = fileManager.enumerator(
            at: projectFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidateFileURLs: [URL] = []
        while let enumeratedItem = directoryEnumerator.nextObject() as? URL {
            let resourceValues = try? enumeratedItem.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if resourceValues?.isDirectory == true {
                // Prune excluded trees instead of filtering their contents —
                // node_modules alone can hold 100k+ entries and enumerating
                // them takes seconds.
                if excludedWebProjectDirectoryNames.contains(enumeratedItem.lastPathComponent) {
                    directoryEnumerator.skipDescendants()
                }
                continue
            }
            guard resourceValues?.isRegularFile == true,
                  includedWebProjectFileExtensions.contains(enumeratedItem.pathExtension.lowercased()),
                  (resourceValues?.fileSize ?? 0) <= maximumWebProjectFileBytes else {
                continue
            }
            candidateFileURLs.append(enumeratedItem)
        }

        let sortedFileURLs = candidateFileURLs.sorted { firstURL, secondURL in
            let firstDepth = firstURL.pathComponents.count
            let secondDepth = secondURL.pathComponents.count
            if firstDepth != secondDepth { return firstDepth < secondDepth }
            return firstURL.path < secondURL.path
        }

        let projectFolderPath = projectFolderURL.standardizedFileURL.path
        var gatheredFiles: [WebProjectFile] = []
        var totalCharacterCount = 0
        for fileURL in sortedFileURLs {
            guard gatheredFiles.count < maximumWebProjectFileCount,
                  totalCharacterCount < maximumTotalWebProjectCharacters else { break }
            guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var includedContents = fileContents
            if includedContents.count > maximumCharactersPerWebProjectFile {
                includedContents = String(includedContents.prefix(maximumCharactersPerWebProjectFile))
                    + webProjectFileTruncationMarker
            }

            var relativePath = fileURL.standardizedFileURL.path
            if relativePath.hasPrefix(projectFolderPath + "/") {
                relativePath = String(relativePath.dropFirst(projectFolderPath.count + 1))
            }
            gatheredFiles.append(WebProjectFile(relativePath: relativePath, contents: includedContents))
            totalCharacterCount += includedContents.count
        }
        return gatheredFiles
    }

    /// Applies the model's search/replace edits to files inside the configured
    /// project folder. Returns how many applied plus a summary of each failure.
    private func applyCodeEditsToProjectFiles(_ codeEdits: [ParsedCodeEdit]) -> (appliedCount: Int, failureSummaries: [String]) {
        guard let projectFolderURL = webProjectFolderURL else {
            return (0, ["no project folder is configured"])
        }
        let projectFolderPath = projectFolderURL.standardizedFileURL.path
        var appliedCount = 0
        var failureSummaries: [String] = []

        for codeEdit in codeEdits {
            let targetFileURL = projectFolderURL
                .appendingPathComponent(codeEdit.relativeFilePath)
                .standardizedFileURL
            // Containment guard: the resolved path must stay inside the
            // project folder so a path like "../../something" can't escape it.
            guard targetFileURL.path.hasPrefix(projectFolderPath + "/") else {
                failureSummaries.append("\(codeEdit.relativeFilePath): path escapes the project folder")
                continue
            }
            guard let originalContents = try? String(contentsOf: targetFileURL, encoding: .utf8) else {
                failureSummaries.append("\(codeEdit.relativeFilePath): could not read file")
                continue
            }
            // The search text always uses bare-LF lines (the response is
            // normalized before parsing). For a CRLF file, fall back to
            // matching against a normalized copy — the write then converts
            // the file to LF, an acceptable trade for the edit applying.
            var contentsToEdit = originalContents
            if originalContents.range(of: codeEdit.searchText) == nil, originalContents.contains("\r\n") {
                contentsToEdit = originalContents.replacingOccurrences(of: "\r\n", with: "\n")
            }
            guard let searchTextRange = contentsToEdit.range(of: codeEdit.searchText) else {
                failureSummaries.append("\(codeEdit.relativeFilePath): search text not found")
                continue
            }
            var updatedContents = contentsToEdit
            updatedContents.replaceSubrange(searchTextRange, with: codeEdit.replacementText)
            do {
                try updatedContents.write(to: targetFileURL, atomically: true, encoding: .utf8)
                appliedCount += 1
            } catch {
                failureSummaries.append("\(codeEdit.relativeFilePath): write failed — \(error.localizedDescription)")
            }
        }
        return (appliedCount, failureSummaries)
    }

    // MARK: - Point Tag Parsing

    /// A single parsed [POINT:x,y:label(:screenN)] coordinate tag.
    struct ParsedPointTag {
        /// The 0–1000 grid coordinate on the screenshot (top-left origin).
        let coordinate: CGPoint
        /// Short label describing the element (e.g. "run button"), or nil if omitted.
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Result of parsing the [POINT:...] tags from the model's response.
    struct PointingParseResult {
        /// The response text with every [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// All coordinate tags in document order — the pointing tour visits
        /// them in this order — capped at `maximumPointingTourStops`. Empty
        /// when the model wrote [POINT:none] or no tag at all.
        let points: [ParsedPointTag]
    }

    /// The maximum number of stops a pointing tour will visit. Tags beyond
    /// this are dropped (tags are in visit order, so the first four are kept).
    static let maximumPointingTourStops = 4

    /// Parses every [POINT:x,y:label:screenN] tag from the model's response.
    /// Tags normally arrive back to back at the very end of the response, but
    /// the model occasionally writes them mid-sentence or adds trailing
    /// punctuation, so matching is deliberately not anchored to the end of the
    /// text. Every tag is stripped from the spoken text; [POINT:none] tags
    /// contribute no points.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Extract coordinate tags: [POINT:123,456:label] or
        // [POINT:123,456:label:screen2]. Case-insensitive and whitespace-
        // tolerant so a casing/spacing drift on the keyword (M3 via Together
        // occasionally writes [Point: 500, 200 : label]) still resolves to a
        // pointing stop. [POINT:none] carries no coordinates and contributes
        // nothing here — it is only stripped from the spoken text below.
        let coordinatePattern = #"\[\s*POINT\s*:\s*(\d+)\s*,\s*(\d+)(?:\s*:\s*([^\]:]+?))?(?:\s*:\s*screen\s*(\d+))?\s*\]"#

        var points: [ParsedPointTag] = []
        if let regex = try? NSRegularExpression(pattern: coordinatePattern, options: [.caseInsensitive]) {
            let fullTextRange = NSRange(responseText.startIndex..., in: responseText)
            for tagMatch in regex.matches(in: responseText, range: fullTextRange) {
                guard let xRange = Range(tagMatch.range(at: 1), in: responseText),
                      let yRange = Range(tagMatch.range(at: 2), in: responseText),
                      let x = Double(responseText[xRange]),
                      let y = Double(responseText[yRange]) else {
                    continue
                }

                // Optional capture groups report NSNotFound when they didn't
                // participate, and Range(_:in:) returns nil for those.
                var elementLabel: String? = nil
                if let labelRange = Range(tagMatch.range(at: 3), in: responseText) {
                    let trimmedLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                    elementLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
                }

                var screenNumber: Int? = nil
                if let screenRange = Range(tagMatch.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                points.append(ParsedPointTag(
                    coordinate: CGPoint(x: x, y: y),
                    elementLabel: elementLabel,
                    screenNumber: screenNumber
                ))
            }
        }

        // Strip EVERY [POINT...] fragment from the spoken text so a tag is never
        // read aloud by TTS — coordinate tags, [POINT:none] in ANY casing or
        // spacing ([POINT: none], [Point:None], ...), AND an unclosed trailing
        // "[POINT:none" left when a generation is truncated mid-tag. The old
        // parser stripped only an exact lowercase, closed [POINT:none], so any
        // drift leaked into TTS (the model "saying" point none). This pass is
        // deliberately broad but never crosses into another "[", so it removes
        // one tag at a time, and it runs even when no coordinate tag matched.
        var spokenText = responseText
        let stripPattern = #"\[\s*POINTS?\s*:[^\[\]]*\]?"#
        if let stripRegex = try? NSRegularExpression(pattern: stripPattern, options: [.caseInsensitive]) {
            let fullTextRange = NSRange(spokenText.startIndex..., in: spokenText)
            spokenText = stripRegex.stringByReplacingMatches(in: spokenText, options: [], range: fullTextRange, withTemplate: "")
        }
        spokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        return PointingParseResult(
            spokenText: spokenText,
            points: Array(points.prefix(maximumPointingTourStops))
        )
    }

    // MARK: - Companion Response Parsing

    /// Result of splitting the model's response into its parts: spoken
    /// critique, optional coding-agent improvement prompt, optional code
    /// edits, and pointing tags.
    struct CompanionResponseParseResult {
        /// The critique with the [PROMPT] block, [EDIT:...] blocks, and every
        /// [POINT:...] tag removed — this is what gets spoken via TTS.
        let spokenText: String
        /// The improvement prompt body (without the [PROMPT]/[/PROMPT]
        /// markers), or nil when the model omitted the block — for example a
        /// re-review turn where the page is good, or a general question.
        let improvementPromptText: String?
        /// Search/replace edits the model wants applied to the project files
        /// (only emitted when the user asked Clicky to apply fixes).
        let codeEdits: [ParsedCodeEdit]
        /// Edit blocks the model emitted that were malformed/invalid and
        /// dropped — the pill must not claim full success when this is > 0.
        let droppedEditBlockCount: Int
        /// Pointing tour stops, same semantics as PointingParseResult.points.
        let points: [ParsedPointTag]
    }

    /// One search/replace edit the model wants applied to a project file.
    struct ParsedCodeEdit {
        let relativeFilePath: String
        /// Text copied verbatim from the file — replaced at its first match.
        let searchText: String
        let replacementText: String
    }

    private static let codeEditOpeningMarkerPrefix = "[EDIT:"
    private static let codeEditSearchMarker = "<<<<<<< SEARCH"
    /// The divider and closer must sit on their own lines, so they are
    /// matched with surrounding newlines — a literal "=======" inside an
    /// expression can't terminate the search text early.
    private static let codeEditDividerMarker = "\n=======\n"
    private static let codeEditClosingMarker = "\n>>>>>>> REPLACE"

    /// Result of extracting [EDIT:...] blocks from the model's response.
    struct CodeEditExtractionResult {
        let responseTextWithoutEditBlocks: String
        let codeEdits: [ParsedCodeEdit]
        /// Blocks that looked like real edit blocks but were malformed or
        /// invalid and got dropped. Surfaced so the confirmation pill never
        /// claims full success when part of the model's output was discarded.
        let droppedEditBlockCount: Int
    }

    /// Extracts every [EDIT:path] search/replace block from the model's
    /// response. Code inside the blocks can contain anything (including
    /// bracket-heavy text), so this runs before point-tag parsing and the
    /// blocks never reach TTS. Safety properties:
    /// - An opener only counts when "[EDIT:" starts a line AND its "]" closes
    ///   on that same line — a conversational mention of "[EDIT:" in prose
    ///   can't hijack parsing.
    /// - All marker searches are bounded at the next block's opener, so a
    ///   malformed block can never borrow markers from the following block;
    ///   it drops only itself and parsing continues.
    /// - Edits whose content still contains conflict-style marker lines
    ///   ("<<<<<<< " / ">>>>>>> ") are rejected — those only appear when a
    ///   marker collision corrupted the block (e.g. the user's file contains
    ///   unresolved git conflict markers).
    /// The safe failure mode is always "no edit", never "spoken code" or a
    /// corrupted write.
    static func extractCodeEditBlocks(from responseText: String) -> CodeEditExtractionResult {
        var remainingText = responseText
        var codeEdits: [ParsedCodeEdit] = []
        var droppedEditBlockCount = 0

        let closingMarkerWithoutLeadingNewline = String(codeEditClosingMarker.dropFirst())

        /// Finds the next line-anchored "[EDIT:" whose "]" sits on the same
        /// line, searching from the given index. Prose mentions are skipped.
        func findNextRealOpeningMarker(from searchStartIndex: String.Index) -> (markerRange: Range<String.Index>, pathRange: Range<String.Index>)? {
            var cursorIndex = searchStartIndex
            while let candidateRange = remainingText.range(of: codeEditOpeningMarkerPrefix, range: cursorIndex..<remainingText.endIndex) {
                let isAtLineStart = candidateRange.lowerBound == remainingText.startIndex
                    || remainingText[remainingText.index(before: candidateRange.lowerBound)] == "\n"
                if isAtLineStart,
                   let closingBracketRange = remainingText.range(of: "]", range: candidateRange.upperBound..<remainingText.endIndex),
                   !remainingText[candidateRange.upperBound..<closingBracketRange.lowerBound].contains("\n") {
                    return (candidateRange, candidateRange.upperBound..<closingBracketRange.lowerBound)
                }
                cursorIndex = candidateRange.upperBound
            }
            return nil
        }

        /// A contaminated search/replacement (marker collision) contains a
        /// line starting with a conflict-style marker.
        func containsConflictMarkerLine(_ text: String) -> Bool {
            text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
                line.hasPrefix("<<<<<<< ") || line.hasPrefix(">>>>>>> ")
            }
        }

        while let openingMarker = findNextRealOpeningMarker(from: remainingText.startIndex) {
            // This block's scope ends where the next block begins — markers
            // can never be borrowed across block boundaries.
            let pathClosingBracketEnd = remainingText.index(after: openingMarker.pathRange.upperBound)
            let blockScopeEnd: String.Index
            if let nextOpeningMarker = findNextRealOpeningMarker(from: pathClosingBracketEnd) {
                blockScopeEnd = nextOpeningMarker.markerRange.lowerBound
            } else {
                blockScopeEnd = remainingText.endIndex
            }

            /// Resolves the block's end within its scope: a closing marker on
            /// its own line, or — for a deletion edit with an EMPTY
            /// replacement — the closing marker directly after the divider,
            /// where the divider's trailing newline doubles as the closer's
            /// leading newline. The empty-replacement check runs FIRST so a
            /// deletion block can never borrow a later block's closer.
            func resolveBlockEnd(after dividerMarkerRange: Range<String.Index>) -> (replacementText: String, blockEndIndex: String.Index)? {
                if remainingText[dividerMarkerRange.upperBound..<blockScopeEnd].hasPrefix(closingMarkerWithoutLeadingNewline) {
                    return (
                        "",
                        remainingText.index(dividerMarkerRange.upperBound, offsetBy: closingMarkerWithoutLeadingNewline.count)
                    )
                }
                if let closingMarkerRange = remainingText.range(of: codeEditClosingMarker, range: dividerMarkerRange.upperBound..<blockScopeEnd) {
                    return (
                        String(remainingText[dividerMarkerRange.upperBound..<closingMarkerRange.lowerBound]),
                        closingMarkerRange.upperBound
                    )
                }
                return nil
            }

            guard let searchMarkerRange = remainingText.range(of: codeEditSearchMarker, range: pathClosingBracketEnd..<blockScopeEnd),
                  let dividerMarkerRange = remainingText.range(of: codeEditDividerMarker, range: searchMarkerRange.upperBound..<blockScopeEnd),
                  let blockEnd = resolveBlockEnd(after: dividerMarkerRange)
            else {
                // Malformed/truncated block: drop ONLY this block — up to the
                // next block's opener, or the next [POINT: tag / end of text
                // when this is the last block — and keep parsing.
                droppedEditBlockCount += 1
                var malformedBlockEnd = blockScopeEnd
                if blockScopeEnd == remainingText.endIndex,
                   let nextPointTagRange = remainingText.range(of: "[POINT:", range: pathClosingBracketEnd..<remainingText.endIndex) {
                    malformedBlockEnd = nextPointTagRange.lowerBound
                }
                remainingText.removeSubrange(openingMarker.markerRange.lowerBound..<malformedBlockEnd)
                continue
            }

            let relativeFilePath = String(remainingText[openingMarker.pathRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // The search text starts on the line after the SEARCH marker.
            var searchText = String(remainingText[searchMarkerRange.upperBound..<dividerMarkerRange.lowerBound])
            if searchText.hasPrefix("\n") { searchText.removeFirst() }

            let isValidEdit = !relativeFilePath.isEmpty
                && !searchText.isEmpty
                && !containsConflictMarkerLine(searchText)
                && !containsConflictMarkerLine(blockEnd.replacementText)
            if isValidEdit {
                codeEdits.append(ParsedCodeEdit(
                    relativeFilePath: relativeFilePath,
                    searchText: searchText,
                    replacementText: blockEnd.replacementText
                ))
            } else {
                droppedEditBlockCount += 1
            }
            remainingText.removeSubrange(openingMarker.markerRange.lowerBound..<blockEnd.blockEndIndex)
        }

        return CodeEditExtractionResult(
            responseTextWithoutEditBlocks: remainingText,
            codeEdits: codeEdits,
            droppedEditBlockCount: droppedEditBlockCount
        )
    }

    private static let improvementPromptOpeningMarker = "[PROMPT]"
    private static let improvementPromptClosingMarker = "[/PROMPT]"

    /// Splits the model's raw response into the spoken critique, the optional
    /// [PROMPT]...[/PROMPT] improvement prompt, the optional [EDIT:...] code
    /// edits, and the [POINT:...] tags. Extraction order is load-bearing:
    /// the PROMPT block comes out FIRST so an edit block the model wrongly
    /// writes inside it stays clipboard text and is never executed against
    /// the user's files; edit blocks come out of the remainder next so code
    /// can never reach TTS or trigger phantom pointing; the point-tag parser
    /// runs last. parsePointingCoordinates itself is untouched because the
    /// onboarding demo also calls it.
    static func parseCompanionResponse(from responseText: String) -> CompanionResponseParseResult {
        // Normalize CRLF up front — the edit-block markers and the spoken
        // text all assume bare-LF lines, and a CRLF-emitting model would
        // otherwise have every block dropped as malformed.
        var remainingResponseText = responseText.replacingOccurrences(of: "\r\n", with: "\n")
        var improvementPromptText: String? = nil

        // The opener must start a line (mirroring the [EDIT:] opener rule) —
        // a prose mention like "no [PROMPT] block this time" must not open a
        // block, because the unterminated-block salvage below would swallow
        // everything after it, including valid [EDIT:...] blocks, and the
        // user would see "prompt copied" while no edits were applied. A
        // mid-line opener is honored only when its [/PROMPT] closer exists,
        // so a genuine block the model failed to line-anchor still extracts
        // instead of leaking its whole body into the spoken text.
        func findImprovementPromptOpeningMarker(in text: String) -> Range<String.Index>? {
            var cursorIndex = text.startIndex
            while let candidateRange = text.range(of: improvementPromptOpeningMarker, range: cursorIndex..<text.endIndex) {
                let isAtLineStart = candidateRange.lowerBound == text.startIndex
                    || text[text.index(before: candidateRange.lowerBound)] == "\n"
                if isAtLineStart { return candidateRange }
                cursorIndex = candidateRange.upperBound
            }
            // No line-anchored opener — accept a mid-line one only when the
            // block is provably real (its closer is present after it).
            if let unanchoredRange = text.range(of: improvementPromptOpeningMarker),
               text.range(of: improvementPromptClosingMarker, range: unanchoredRange.upperBound..<text.endIndex) != nil {
                return unanchoredRange
            }
            return nil
        }

        if let openingMarkerRange = findImprovementPromptOpeningMarker(in: remainingResponseText) {
            let textAfterOpeningMarker = remainingResponseText[openingMarkerRange.upperBound...]

            if let closingMarkerRange = textAfterOpeningMarker.range(of: improvementPromptClosingMarker) {
                // Well-formed block: the prompt is the text between the markers.
                improvementPromptText = String(textAfterOpeningMarker[..<closingMarkerRange.lowerBound])
                remainingResponseText = String(remainingResponseText[..<openingMarkerRange.lowerBound])
                    + String(textAfterOpeningMarker[closingMarkerRange.upperBound...])
            } else if let firstPointTagRange = textAfterOpeningMarker.range(of: "[POINT:") {
                // Unterminated block (the model forgot [/PROMPT] or generation
                // was truncated): the prompt ends where the tags begin, so the
                // tags still drive the pointing tour and the block's contents
                // can never leak into the spoken text.
                improvementPromptText = String(textAfterOpeningMarker[..<firstPointTagRange.lowerBound])
                remainingResponseText = String(remainingResponseText[..<openingMarkerRange.lowerBound])
                    + String(textAfterOpeningMarker[firstPointTagRange.lowerBound...])
            } else {
                // Unterminated block with no tags at all: everything after the
                // opening marker is the prompt.
                improvementPromptText = String(textAfterOpeningMarker)
                remainingResponseText = String(remainingResponseText[..<openingMarkerRange.lowerBound])
            }
        }

        // Strip any stray markers so TTS never reads bracket junk, and treat
        // an empty or whitespace-only block as absent (no clipboard write,
        // no overlay).
        remainingResponseText = remainingResponseText
            .replacingOccurrences(of: improvementPromptOpeningMarker, with: "")
            .replacingOccurrences(of: improvementPromptClosingMarker, with: "")
        let trimmedImprovementPromptText = improvementPromptText?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Edit blocks come out of the post-prompt remainder, so a block
        // nested inside [PROMPT] is clipboard text, never an applied edit.
        let codeEditExtractionResult = extractCodeEditBlocks(from: remainingResponseText)

        let pointingParseResult = parsePointingCoordinates(from: codeEditExtractionResult.responseTextWithoutEditBlocks)

        return CompanionResponseParseResult(
            // Trim again here: removing the blocks can leave whitespace
            // behind, and parsePointingCoordinates returns its input untrimmed
            // when the response contains no tags.
            spokenText: pointingParseResult.spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
            improvementPromptText: (trimmedImprovementPromptText?.isEmpty == false) ? trimmedImprovementPromptText : nil,
            codeEdits: codeEditExtractionResult.codeEdits,
            droppedEditBlockCount: codeEditExtractionResult.droppedEditBlockCount,
            points: pointingParseResult.points
        )
    }

    /// Converts a model coordinate on the 0–1000 screenshot grid (top-left
    /// origin) to a global AppKit screen point (bottom-left origin) on the
    /// captured display.
    private static func convertGridPointToGlobalScreenLocation(
        _ gridPoint: CGPoint,
        on screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let coordinateGridMax: CGFloat = 1000
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        // Clamp to the 0–1000 coordinate grid
        let clampedX = max(0, min(gridPoint.x, coordinateGridMax))
        let clampedY = max(0, min(gridPoint.y, coordinateGridMax))

        // Scale from the 0–1000 grid to display points
        let displayLocalX = clampedX * (displayWidth / coordinateGridMax)
        let displayLocalY = clampedY * (displayHeight / coordinateGridMax)

        // Convert from top-left origin (grid) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. coordinates use a 0 to 1000 grid laid over the image, so your x coordinate must be between 200 and 800, and your y coordinate must be between 200 and 800. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    coordinates are on a 0 to 1000 grid laid over the screenshot: (0,0) is the top-left corner of the image, (1000,1000) is the bottom-right corner. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks MiniMax to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so the model can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label)]

                let (fullResponseText, _) = try await miniMaxAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let firstPoint = parseResult.points.first else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                // Single-stop tour with the model's comment as the bubble text —
                // it takes the place of the tag's label for the demo.
                startPointingTour([PointingTourStop(
                    screenLocation: Self.convertGridPointToGlobalScreenLocation(firstPoint.coordinate, on: cursorScreenCapture),
                    displayFrame: cursorScreenCapture.displayFrame,
                    bubbleText: parseResult.spokenText
                )])
                print("🎯 Onboarding demo: pointing at \"\(firstPoint.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
