import AppKit
import AVFoundation
import SwiftUI

enum OnboardingVideoResource {
    static let baseName = "third-hand-logo-transparent"
    static let fileExtension = "mov"
    static let posterBaseName = "third-hand-logo-poster"

    static var url: URL? {
        Bundle.module.url(
            forResource: baseName,
            withExtension: fileExtension
        )
    }

    static var posterURL: URL? {
        Bundle.module.url(
            forResource: posterBaseName,
            withExtension: "png"
        )
    }
}

struct OnboardingVideoView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView(frame: .zero)
        view.playerLayer.player = context.coordinator.player
        context.coordinator.player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {}

    static func dismantleNSView(
        _ nsView: PlayerContainerView,
        coordinator: Coordinator
    ) {
        coordinator.player.pause()
        nsView.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        let player: AVPlayer

        init(url: URL) {
            let item = AVPlayerItem(url: url)
            item.forwardPlaybackEndTime = CMTime(
                seconds: 5.5,
                preferredTimescale: 600
            )

            let player = AVPlayer(playerItem: item)
            self.player = player
            player.actionAtItemEnd = .pause
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
