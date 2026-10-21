import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Fire the shutter automatically", isOn: $settings.autoShutter)
                    Toggle("Speak the directions", isOn: $settings.spokenDirections)
                    Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
                } header: {
                    Text("Shooting")
                } footer: {
                    Text("With auto-shutter on, the photo is taken the moment the framing locks and you've held it steady for a beat.")
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
