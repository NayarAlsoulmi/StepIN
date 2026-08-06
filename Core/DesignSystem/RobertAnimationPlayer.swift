//
//  RobertAnimationPlayer.swift
//  StepIN
//
//  Sprite-sheet animation engine for the Robert character.
//
//  Frame loading and one-shot completion are driven by a stable playback
//  controller — never by .task(id:) view-modifier form. Frame advancement uses
//  TimelineView so sprite playback has an explicit render cadence.
//
//  WHY: On iOS 26, .task(id:) creates a DynamicContainer layout node inside
//  the view modifier chain. When that container re-evaluates (e.g. when
//  animRunning changes) while the view is inside NavigationStack → ScrollView,
//  SwiftUI calls DynamicContainer.makeContainer from within ModifiedElements
//  .makeElements, which calls it again from the same context. The call stack
//  grows linearly with each modifier in the hierarchy until it overflows.
//  Using @State-stored Tasks avoids placing any DynamicContainer in the chain.
//

import SwiftUI
import UIKit
import Observation

// True when the process is the Xcode Preview host. All animation tasks,
// timers, and frame loads are skipped in preview to prevent rapid
// re-evaluation of #Preview closures from recreating ModelContainers
// and triggering DynamicContainer layout recursion.
private let isXcodePreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

// MARK: - RobertAnimationState

enum RobertAnimationState: String, CaseIterable {
    case idle, listening, speaking, thinking, analyzing, paused
    case wave, success, thumbsUp, wakeUp, confused

    var sequenceName: String { rawValue }

    var isOneShot: Bool {
        switch self {
        case .wave, .success, .thumbsUp, .wakeUp, .confused: true
        default: false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:      "Robert is ready"
        case .listening: "Robert is listening"
        case .speaking:  "Robert is speaking"
        case .thinking:  "Robert is thinking"
        case .analyzing: "Robert is analyzing the interview"
        case .paused:    "Robert is paused"
        case .wave:      "Robert is saying goodbye"
        case .success:   "Robert is celebrating your completed interview"
        case .thumbsUp:  "Robert is celebrating your completed interview"
        case .wakeUp:    "Robert is ready"
        case .confused:  "Robert is paused"
        }
    }
}

// MARK: - RobertSpriteAnimation

struct RobertSpriteAnimation: Sendable {
    let name: String
    let frameCount: Int
    let fps: Int
    let loop: Bool
}

// MARK: - RobertFrameCache

/// Singleton that loads and caches decoded UIImage frames.
/// All mutations happen on MainActor; frame decoding is offloaded
/// to a background Task. Evicts caches on memory warning.
@MainActor
final class RobertFrameCache {
    static let shared = RobertFrameCache()

    private var animations: [String: RobertSpriteAnimation] = [:]
    private var frameStore: [String: [UIImage]] = [:]
    private static let fallback = makeFallbackImage()

    private init() {
        loadManifest()
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                self?.frameStore.removeAll()
            }
        }
    }

    func animation(for state: RobertAnimationState) -> RobertSpriteAnimation? {
        animations[state.sequenceName]
    }

    func frames(for state: RobertAnimationState) async -> [UIImage] {
        let name = state.sequenceName
        if let cached = frameStore[name] { return cached }
        let loaded = await Task.detached(priority: .userInitiated) {
            RobertFrameCache.loadFramesFromBundle(sequenceName: name)
        }.value
        frameStore[name] = loaded
        return loaded
    }

    static var fallbackImage: UIImage { fallback }

    nonisolated private static func makeFallbackImage() -> UIImage {
        if let namedFallback = UIImage(named: "StepINRobot") {
            return namedFallback
        }

        for sequenceName in ["idle", "wakeUp", "wave"] {
            if let firstFrame = loadFramesFromBundle(sequenceName: sequenceName).first {
                return firstFrame
            }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
    }

    // MARK: Bundle loading (nonisolated — runs on background thread)

    nonisolated private static func loadFramesFromBundle(sequenceName: String) -> [UIImage] {
        frameURLs(sequenceName: sequenceName)
            .compactMap { UIImage(contentsOfFile: $0.path) }
    }

    nonisolated private static func frameURL(sequenceName: String, frameName: String) -> URL? {
        let candidates: [String?] = [
            "RobertAnimations/\(sequenceName)",
            "StepIN/RobertAnimations/\(sequenceName)",
            sequenceName,
            nil
        ]
        for subdir in candidates {
            if let url = Bundle.main.url(
                forResource: frameName, withExtension: "png", subdirectory: subdir
            ) { return url }
        }
        return nil
    }

    nonisolated private static func frameURLs(sequenceName: String) -> [URL] {
        let subdirs: [String?] = [
            "RobertAnimations/\(sequenceName)",
            "StepIN/RobertAnimations/\(sequenceName)",
            sequenceName,
            nil
        ]

        let prefixedURLs = subdirs.flatMap { subdir in
            Bundle.main.urls(
                forResourcesWithExtension: "png",
                subdirectory: subdir
            ) ?? []
        }
        .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("\(sequenceName)_") }

        if !prefixedURLs.isEmpty {
            return prefixedURLs.sorted { lhs, rhs in
                frameNumber(from: lhs, sequenceName: sequenceName) < frameNumber(from: rhs, sequenceName: sequenceName)
            }
        }

        var sequentialURLs: [URL] = []
        var index = 0
        while true {
            let frameName = String(format: "%@_%03d", sequenceName, index)
            guard let url = frameURL(sequenceName: sequenceName, frameName: frameName) else { break }
            sequentialURLs.append(url)
            index += 1
        }
        return sequentialURLs
    }

    nonisolated private static func frameNumber(from url: URL, sequenceName: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "\(sequenceName)_"
        guard name.hasPrefix(prefix) else { return .max }
        return Int(name.dropFirst(prefix.count)) ?? .max
    }

    // MARK: Manifest

    private func loadManifest() {
        let subdirs: [String?] = ["RobertAnimations", "StepIN/RobertAnimations", nil]
        for subdir in subdirs {
            guard let url = Bundle.main.url(
                forResource: "animation_manifest", withExtension: "json", subdirectory: subdir
            ), let data = try? Data(contentsOf: url),
               let manifest = try? JSONDecoder().decode(AnimationManifest.self, from: data)
            else { continue }
            for seq in manifest.sequences {
                animations[seq.name] = RobertSpriteAnimation(
                    name: seq.name, frameCount: seq.frameCount, fps: seq.fps, loop: seq.loop
                )
            }
            return
        }
        hardcodeAnimations()
    }

    private func hardcodeAnimations() {
        let specs: [(String, Int, Int, Bool)] = [
            ("idle",      12, 12, true),
            ("listening", 10, 12, true),
            ("speaking",  12, 15, true),
            ("thinking",  12, 12, true),
            ("analyzing", 12, 12, true),
            ("paused",     1,  1, false),
            ("wave",      12, 15, false),
            ("success",   10, 15, false),
            ("thumbsUp",  10, 15, false),
            ("wakeUp",    12, 15, false),
            ("confused",  10, 12, false),
        ]
        for (name, count, fps, loop) in specs {
            animations[name] = RobertSpriteAnimation(
                name: name, frameCount: count, fps: fps, loop: loop
            )
        }
    }
}

private struct AnimationManifest: Decodable {
    let sequences: [SequenceEntry]
    struct SequenceEntry: Decodable {
        let name: String
        let frameCount: Int
        let fps: Int
        let loop: Bool
    }
}

// MARK: - RobertSpritePlaybackController

@MainActor
@Observable
private final class RobertSpritePlaybackController {
    private(set) var frames: [UIImage] = []
    private(set) var animation: RobertSpriteAnimation? = nil
    private(set) var sequenceName = ""
    private(set) var playbackStartDate = Date.now

    private var loadTask: Task<Void, Never>? = nil
    private var completionTask: Task<Void, Never>? = nil
    private var completedSequenceName: String? = nil

    func start(
        state: RobertAnimationState,
        reduceMotion: Bool,
        onComplete: (() -> Void)?
    ) {
        let newSequenceName = state.sequenceName
        guard newSequenceName != sequenceName || frames.isEmpty else { return }

        sequenceName = newSequenceName
        frames = []
        animation = nil
        playbackStartDate = .now
        completedSequenceName = nil

        loadTask?.cancel()
        completionTask?.cancel()
        completionTask = nil

        loadTask = Task { [weak self] in
            let cache = RobertFrameCache.shared
            let loadedAnimation = cache.animation(for: state)
            let loadedFrames = await cache.frames(for: state)
            guard !Task.isCancelled else { return }

            self?.apply(
                animation: loadedAnimation,
                frames: loadedFrames,
                state: state,
                reduceMotion: reduceMotion,
                onComplete: onComplete
            )
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        completionTask?.cancel()
        completionTask = nil
    }

    func currentFrame(
        at date: Date,
        reduceMotion: Bool,
        scenePhase: ScenePhase
    ) -> UIImage {
        guard !frames.isEmpty else { return RobertFrameCache.fallbackImage }
        guard !reduceMotion,
              scenePhase != .background,
              let animation,
              animation.fps > 0
        else { return frames[0] }

        let index = frameIndex(at: date)
        return frames[index]
    }

    func frameIndex(at date: Date) -> Int {
        guard !frames.isEmpty,
              let animation,
              animation.fps > 0
        else { return 0 }

        let elapsed = max(0, date.timeIntervalSince(playbackStartDate))
        let calculatedIndex = Int((elapsed * Double(animation.fps)).rounded(.down))
        return animation.loop
            ? calculatedIndex % frames.count
            : min(calculatedIndex, frames.count - 1)
    }

    private func apply(
        animation loadedAnimation: RobertSpriteAnimation?,
        frames loadedFrames: [UIImage],
        state: RobertAnimationState,
        reduceMotion: Bool,
        onComplete: (() -> Void)?
    ) {
        animation = loadedAnimation ?? RobertSpriteAnimation(
            name: state.sequenceName,
            frameCount: loadedFrames.count,
            fps: state.isOneShot ? 15 : 12,
            loop: !state.isOneShot
        )
        frames = loadedFrames
        playbackStartDate = .now

        guard !loadedFrames.isEmpty,
              state.isOneShot,
              let animation
        else { return }

        let duration: Duration = reduceMotion
            ? .milliseconds(150)
            : .seconds(Double(max(animation.frameCount, loadedFrames.count)) / Double(max(animation.fps, 1)))
        let completingSequenceName = state.sequenceName
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled,
                  self?.sequenceName == completingSequenceName,
                  self?.completedSequenceName != completingSequenceName
            else { return }

            self?.completedSequenceName = completingSequenceName
            onComplete?()
        }
    }
}

// MARK: - RobertAnimationPlayer

/// Displays the Robert sprite animation for a given state.
///
/// Imperative task management: frame loading and the playback loop are stored
/// in @State Task references and started/stopped via .onAppear/.onChange/.onDisappear.
/// This avoids .task(id:) view modifiers, which create DynamicContainer layout nodes
/// that trigger layout recursion on iOS 26 inside ScrollView + NavigationStack.
struct RobertAnimationPlayer: View {
    let state: RobertAnimationState
    let size: CGFloat
    var audioLevel: Double = 0
    var onComplete: (() -> Void)? = nil

    @State private var playback = RobertSpritePlaybackController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Image(uiImage: playback.currentFrame(
                at: timeline.date,
                reduceMotion: reduceMotion,
                scenePhase: scenePhase
            ))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
        // All async work is skipped in Preview to keep Canvas stable.
        .onAppear { guard !isXcodePreview else { return }; beginPlayback() }
        .onChange(of: state) { _, _ in guard !isXcodePreview else { return }; beginPlayback() }
        .onDisappear {
            guard !isXcodePreview else { return }
            playback.cancel()
        }
        .accessibilityElement()
        .accessibilityLabel(state.accessibilityLabel)
    }

    private func beginPlayback() {
        playback.start(
            state: state,
            reduceMotion: reduceMotion,
            onComplete: onComplete
        )
    }
}

// MARK: - Preview

#Preview("All states") {
    ScrollView {
        LazyVGrid(columns: [GridItem(), GridItem(), GridItem()], spacing: 16) {
            ForEach(RobertAnimationState.allCases, id: \.self) { state in
                VStack(spacing: 4) {
                    RobertAnimationPlayer(state: state, size: 80)
                    Text(state.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
