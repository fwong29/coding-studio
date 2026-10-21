import AVFoundation
import SwiftUI
import UIKit

/// The whole app, essentially: live preview, the assignment telling you what
/// to shoot, the overlay showing you how to frame it, and a shutter that
/// mostly fires itself.
struct CameraScreen: View {

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = CameraController()
    @StateObject private var director: ShotDirector

    @State private var isCardExpanded = false
    @State private var showingSettings = false
    @State private var showingReview = false
    @State private var focusIndicator: CGPoint?
    @State private var zoomBase: CGFloat = 1
    @State private var toastTask: Task<Void, Never>?

    init() {
        // Read the stored preference directly: the director starts location
        // services in its initializer, and `@EnvironmentObject` isn't
        // available this early.
        let useLocation = UserDefaults.standard
            .object(forKey: AppSettings.Keys.useLocation) as? Bool ?? true
        _director = StateObject(wrappedValue: ShotDirector(useLocation: useLocation))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionDenied {
                permissionPrompt
            } else {
                preview
                overlayLayer
                chrome
            }

            if let toast = camera.toast {
                VStack {
                    Spacer()
                    ToastView(message: toast)
                        .padding(.bottom, 180)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: camera.toast)
        .onAppear(perform: activate)
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showingSettings) {
            SettingsView { showingSettings = false }
                .environmentObject(settings)
        }
        .sheet(isPresented: $showingReview) {
            if let capture = camera.lastCapture {
                CaptureReviewView(capture: capture) { showingReview = false }
            }
        }
        // Keep the controller in step with preference changes.
        .onChange(of: settings.autoShutter) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.spokenDirections) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.hapticFeedback) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.autoEdit) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.autoStraighten) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.keepOriginal) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.useAppleAutoEnhance) { _, _ in camera.applySettings(settings) }
        .onChange(of: settings.albumName) { _, _ in camera.applySettings(settings) }
        // The active assignment reconfigures what the coach asks for.
        .onChange(of: director.current) { _, assignment in
            camera.setAssignmentTarget(assignment?.framing)
        }
        .onChange(of: director.sun.phase) { _, phase in
            camera.setLightPhase(phase)
        }
        // Feed the observed scene back so assignments match what you're
        // actually pointing at.
        .onChange(of: camera.coaching.sceneKind) { _, kind in
            director.noteScene(kind)
        }
        .onChange(of: camera.toast) { _, value in
            guard value != nil else { return }
            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                camera.clearToast()
            }
        }
    }

    // MARK: - Setup

    private func activate() {
        camera.applySettings(settings)
        camera.setLightPhase(director.sun.phase)
        camera.setAssignmentTarget(director.current?.framing)
        camera.onSaved = {
            director.markCompleted()
        }
        camera.start()
    }

    // MARK: - Layers

    private var preview: some View {
        GeometryReader { proxy in
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let mapper = PreviewMapper(viewSize: proxy.size,
                                               contentAspect: camera.videoAspect)
                    camera.focus(atFrameSpacePoint: mapper.normalized(location))
                    withAnimation(.easeOut(duration: 0.15)) { focusIndicator = location }
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        withAnimation(.easeOut(duration: 0.3)) { focusIndicator = nil }
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            camera.setZoom(zoomBase * scale)
                        }
                        .onEnded { scale in
                            zoomBase = clamp(zoomBase * scale, 1, 8)
                        }
                )
                .overlay {
                    if let point = focusIndicator {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.yellow, lineWidth: 1.2)
                            .frame(width: 64, height: 64)
                            .position(point)
                            .transition(.opacity)
                    }
                }
        }
    }

    private var overlayLayer: some View {
        FramingOverlay(state: camera.coaching,
                       videoAspect: camera.videoAspect,
                       showGrid: settings.showGrid,
                       showHorizon: settings.showHorizon)
            .ignoresSafeArea()
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            AssignmentCard(assignment: director.current,
                           lightSummary: director.lightSummary,
                           sceneLabel: camera.coaching.sceneLabel,
                           isExpanded: $isCardExpanded,
                           onShuffle: { director.next() })
                .padding(.horizontal, 14)
                .padding(.top, 8)

            Spacer(minLength: 0)

            DirectiveBanner(directive: camera.directive,
                            isReady: camera.coaching.isReady)

            controls
        }
        .padding(.top, 44)
        .padding(.bottom, 28)
    }

    private var controls: some View {
        HStack {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            ShutterButton(readiness: camera.coaching.readiness,
                          isReady: camera.coaching.isReady,
                          isCapturing: camera.isCapturing,
                          autoShutterOn: settings.autoShutter) {
                camera.capture()
            }

            Spacer()

            Button {
                guard camera.lastCapture != nil else { return }
                showingReview = true
            } label: {
                Group {
                    if let thumbnail = camera.lastCapture?.afterThumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(camera.lastCapture == nil)
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.8)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access needed")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Framewise can't coach a frame it can't see. Turn the camera on in Settings › Privacy › Camera.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}
