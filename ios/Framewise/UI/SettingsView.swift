import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Hand me shots to go and find", isOn: $settings.useAssignments)
                } header: {
                    Text("Coaching")
                } footer: {
                    Text("Off, the panel reads whatever you point the camera at and tells you where to stand, how high to hold it and which way the light should come from. On, it hands you shots to go and find from a library of 24 instead.")
                }

                Section {
                    Toggle("Crop to the suggested box", isOn: $settings.cropToSuggestion)
                    Toggle("Fire the shutter automatically", isOn: $settings.autoShutter)
                    Toggle("Speak the directions", isOn: $settings.spokenDirections)
                    Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
                } header: {
                    Text("Shooting")
                } footer: {
                    Text("The yellow box marks the better photo inside what you're pointing at. With cropping on, pressing the shutter gives you exactly that box; turn it off and you keep the full frame with the box as guidance only.\n\nAuto-shutter fires by itself once the framing locks. It's off by default — knowing when the moment is right is the one decision worth keeping.")
                }

                Section {
                    Toggle("Auto-edit every photo", isOn: $settings.autoEdit)
                    Toggle("Straighten the horizon", isOn: $settings.autoStraighten)
                    Toggle("Also keep the unedited original", isOn: $settings.keepOriginal)
                    Toggle("Run Apple's auto-enhance first", isOn: $settings.useAppleAutoEnhance)
                } header: {
                    Text("Editing")
                } footer: {
                    Text("Editing is tuned to what the photo is of — food, a portrait and a night scene each get different treatment. Apple's auto-enhance is a decent general-purpose pass, but it doesn't know the scene, so stacking it under ours can over-correct.")
                }

                Section {
                    Toggle("Thirds grid", isOn: $settings.showGrid)
                    Toggle("Horizon and level", isOn: $settings.showHorizon)
                } header: {
                    Text("Overlay")
                }

                Section {
                    Toggle("Use location for sun position", isOn: $settings.useLocation)
                    TextField("Album name", text: $settings.albumName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Library and light")
                } footer: {
                    Text("Location is used only to work out where the sun is, so the app can time golden hour and tell you which way the light is coming from. It is never stored or sent anywhere. Turn it off and the app falls back to the clock — the change takes effect next time you open the app.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
