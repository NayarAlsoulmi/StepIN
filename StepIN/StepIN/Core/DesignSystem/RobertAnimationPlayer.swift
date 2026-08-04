//
//  RobertAnimationPlayer.swift
//  StepIN
//
//  Sprite-sheet animation engine for the Robert character.
//  Reads frame sequences from the bundled RobertAnimations folder and
//  plays them efficiently using TimelineView. Frames are decoded once
//  per session and kept in memory. Never modifies the source PNGs.
//

import SwiftUI
import UIKit

// MARK: - RobertAnimationState

enum RobertAnimationState: String, CaseIterable {
    case idle, listening, speaking, thinking, analyzing, paused
    case wave, success, thumbsUp, wakeUp, confused

    var sequenceName: String { rawValue }

    // One-shot states play once and stop on the last frame.
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
/// to a background Task.
@MainActor
final class RobertFrameCache {
    static let shared = RobertFrameCache()

    private var animations: [String: RobertSpriteAnimation] = [:]
    private var frameStore: [String: [UIImage]] = [:]

    private init() {
        loadManifest()
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
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

    // MARK: Bundle loading (nonisolated — runs on background thread)

    nonisolated private static func loadFramesFromBundle(sequenceName: String) -> [UIImage] {
        var result: [UIImage] = []
        var index = 0
        while true {
            let fname = String(format: "%@_%03d", sequenceName, index)
            guard let url = frameURL(sequenceName: sequenceName, frameName: fname),
                  let img = UIImage(contentsOfFile: url.path)
            else { break }
            result.append(img)
            index += 1
        }
        return result
    }

    nonisolated private static func frameURL(sequenceName: String, frameName: String) -> URL? {
        // Try multiple candidate paths for robustness across different
        // Xcode synchronized-group bundle layouts.
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
            animations[name] = RobertSpriteAnimation(name: name, frameCount: count, fps: fps, loop: loop)
        }
    }
}

// JSON shape matching animation_manifest.json
private struct AnimationManifest: Decodable {
    let sequences: [SequenceEntry]
    struct SequenceEntry: Decodable {
        let name: String
        let frameCount: Int
        let fps: Int
        let loop: Bool
    }
}

// MARK: - RobertAnimationPlayer

/// Displays the Robert sprite animation for a given state.
/// Uses a display-linked TimelineView for efficiency.
/// Falls back to the static StepINRobot asset when frames are unavailable.
struct RobertAnimationPlayer: View {
    let state: RobertAnimationState
    let size: CGFloat
    var audioLevel: Double = 0
    var onComplete: (() -> Void)? = nil

    @State private var frames: [UIImage] = []
    @State private var anim: RobertSpriteAnimation? = nil
    @State private var startDate = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if frames.isEmpty {
                Image("StepINRobot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else if reduceMotion {
                Image(uiImage: frames[0])
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                TimelineView(.animation(paused: scenePhase != .active)) { context in
                    Image(uiImage: frames[frameIndex(at: context.date)])
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                }
            }
        }
        .task(id: state) {
            startDate = Date()
            let cache = RobertFrameCache.shared
            let loadedAnim = cache.animation(for: state)
            let loadedFrames = await cache.frames(for: state)
            guard !Task.isCancelled else { return }
            anim = loadedAnim
            frames = loadedFrames
            startDate = Date()

            // One-shot completion callback.
            guard let loadedAnim, state.isOneShot else { return }
            let duration: Duration = reduceMotion
                ? .milliseconds(150)
                : .seconds(Double(loadedAnim.frameCount) / Double(loadedAnim.fps))
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            onComplete?()
        }
        .accessibilityElement()
        .accessibilityLabel(state.accessibilityLabel)
    }

    private func frameIndex(at date: Date) -> Int {
        guard let anim, !frames.isEmpty else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(startDate))
        let speedMult: Double = state == .speaking
            ? (0.85 + 0.3 * max(0, min(1, audioLevel)))
            : 1.0
        let fps = Double(anim.fps) * speedMult
        guard fps > 0 else { return 0 }
        let count = frames.count

        if anim.loop {
            let period = Double(count) / fps
            guard period > 0 else { return 0 }
            let t = elapsed.truncatingRemainder(dividingBy: period)
            return min(Int(t * fps), count - 1)
        } else {
            let maxT = Double(count - 1) / fps
            let t = min(elapsed, maxT)
            return min(Int(t * fps), count - 1)
        }
    }
}

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
