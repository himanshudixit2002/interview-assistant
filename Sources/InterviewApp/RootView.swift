import SwiftUI
import InterviewCore

enum Section: String, CaseIterable, Identifiable {
    case profile = "Profile & evidence", stories = "Story library", targets = "Interview targets", mock = "Practice", session = "Live session", review = "Review", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .profile: return "person.text.rectangle"; case .stories: return "book"; case .targets: return "target"; case .mock: return "figure.mind.and.body"
        case .session: return "waveform.and.mic"; case .review: return "chart.bar.doc.horizontal"; case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: Section = ["session", "setup"].contains(ProcessInfo.processInfo.environment["IA_SCENARIO"] ?? "") ? .session : .profile
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                SwiftUI.Section("Prepare") { ForEach([Section.profile, .stories, .targets]) { row($0) } }
                SwiftUI.Section("Practice and assist") { ForEach([Section.mock, .session]) { row($0) } }
                SwiftUI.Section("Afterwards") { ForEach([Section.review, .settings]) { row($0) } }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch section {
                case .profile: ProfileView()
                case .stories: StoriesView()
                case .targets: TargetsView()
                case .mock: MockView()
                case .session: SessionView()
                case .review: ReviewView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.statusMessage.isEmpty {
                HStack { Text(model.statusMessage).font(.callout).lineLimit(2); Spacer(); Button("Dismiss") { model.statusMessage = "" } }
                    .padding(8).background(.bar)
            }
        }
        .onAppear { showOnboarding = !model.onboardingDone }
        .onChange(of: model.onboardingDone) { _, done in if done { showOnboarding = false } }
        .sheet(isPresented: $showOnboarding) { OnboardingView(isPresented: $showOnboarding).environmentObject(model) }
    }

    private func row(_ s: Section) -> some View { Label(s.rawValue, systemImage: s.icon).tag(s) }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(["How this app helps", "What it captures", "Your evidence", "Privacy defaults"][step]).font(.title2.bold())
            Group {
                switch step {
                case 0:
                    Text("Three uses: **prepare** (résumé facts, stories, job targets), **practice** (mock questions with a review), and **permitted live assistance** (captions and short suggestions during an interview where help is allowed).")
                    Text("Suggestions about your own experience only use claims you have approved. When the evidence is missing, the app says so instead of inventing a story.")
                case 1:
                    Text("Nothing is captured until you press Start in a session. You choose one meeting application for audio and, optionally, one window for text recognition. Permissions are requested only when a feature needs them.")
                    Text("A compact panel can stay visible; it is an ordinary window and remains visible to screen sharing. This app does not hide from recordings or proctoring.")
                case 2:
                    Text("Import a résumé (PDF or text). The app proposes claims; approve, edit or reject each one. Then add stories (situation, task, action, result, lesson).")
                    Button("Import a résumé now…") { importResume() }
                default:
                    Text("Everything is stored encrypted on this Mac. No transcript is saved unless you choose Save after a session. Saved sessions auto-delete after \(model.retention.savedSessionDays) days. Cloud reasoning is off until you add a provider key in Settings; local-only mode keeps captions and question detection on device.")
                }
            }
            .font(.body)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 { Button("Next") { step += 1 }.keyboardShortcut(.defaultAction) } else { Button("Start using the app") { model.finishOnboarding(); isPresented = false }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(28)
        .frame(width: 560, height: 380)
    }

    private func importResume() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importDocument(at: url) }
    }
}
