import SwiftUI
import InterviewCore
import InterviewEvidence

struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: ApprovalState? = .proposed
    @State private var editing: VerifiedClaim?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profile & evidence").font(.title2.bold())
                Spacer()
                Button("Import résumé…") { importDocument() }
                Button("Approve all proposed") { model.approveAll(in: nil) }.disabled(!model.claims.contains { $0.state == .proposed && $0.category != .contact })
            }
            if model.documents.isEmpty {
                ContentUnavailableView("No documents yet", systemImage: "doc.text", description: Text("Import a résumé as PDF or text. Claims are proposed for your approval; nothing is treated as verified until you approve it."))
            } else {
                HStack(spacing: 8) {
                    ForEach(model.documents) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.kind == .pdf ? "doc.richtext" : "doc.plaintext")
                            Text(d.filename).lineLimit(1)
                            Text("\(model.claims.filter { $0.documentID == d.id && $0.state == .approved }.count)/\(model.claims.filter { $0.documentID == d.id }.count) approved").foregroundStyle(.secondary).font(.caption)
                            Button(role: .destructive) { model.deleteDocument(d.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
                }
                if !model.contradictions.isEmpty {
                    GroupBox("Please resolve") {
                        ForEach(Array(model.contradictions.enumerated()), id: \.offset) { _, f in Text("• " + f.message).font(.callout) }
                    }
                }
                Picker("Show", selection: $filter) {
                    Text("Proposed").tag(ApprovalState?.some(.proposed)); Text("Approved").tag(ApprovalState?.some(.approved)); Text("Rejected").tag(ApprovalState?.some(.rejected)); Text("All").tag(ApprovalState?.none)
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                List {
                    ForEach(ClaimCategory.allCases, id: \.self) { category in
                        let rows = model.claims.filter { (filter == nil || $0.state == filter) && $0.category == category }
                        if !rows.isEmpty {
                            SwiftUI.Section(category.label) {
                                ForEach(rows) { claim in ClaimRow(claim: claim, onEdit: { editing = claim }) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .sheet(item: $editing) { claim in ClaimEditor(claim: claim).environmentObject(model) }
    }

    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importDocument(at: url) }
    }
}

struct ClaimRow: View {
    @EnvironmentObject var model: AppModel
    let claim: VerifiedClaim
    let onEdit: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(claim.text).font(.body)
                HStack(spacing: 8) {
                    Text(claim.state.rawValue.capitalized).font(.caption).foregroundStyle(claim.state == .approved ? .green : claim.state == .rejected ? .red : .secondary)
                    if let r = claim.sourceRange { Text("source: \(r)").font(.caption).foregroundStyle(.secondary) }
                    if claim.userEdited { Text("edited").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if claim.category == .contact {
                Text("Contact details are never used as evidence").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Edit", action: onEdit).buttonStyle(.borderless)
                Button("Approve") { model.updateClaim(claim, state: .approved) }.disabled(claim.state == .approved)
                Button("Reject") { model.updateClaim(claim, state: .rejected) }.disabled(claim.state == .rejected)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ClaimEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var claim: VerifiedClaim
    @State private var text = ""
    @State private var category: ClaimCategory = .other
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit claim").font(.headline)
            Text("Keep it to what you can defend in the interview. Numbers and ownership should match what happened.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 120).font(.body)
            Picker("Category", selection: $category) { ForEach(ClaimCategory.allCases.filter { $0 != .contact }, id: \.self) { Text($0.label).tag($0) } }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save and approve") { model.updateClaim(claim, state: .approved, text: text, category: category); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
        .onAppear { text = claim.text; category = claim.category }
    }
}

struct StoriesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Story?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Story library").font(.title2.bold()); Spacer(); Button("New story") { editing = Story(title: "") } }
            Text("Situation, task, action, result, lesson. Leave the result empty rather than guessing a number; link the claims each story rests on.").font(.callout).foregroundStyle(.secondary)
            if model.stories.isEmpty {
                ContentUnavailableView("No stories yet", systemImage: "book", description: Text("Add three to five examples that cover ownership, conflict, failure and impact."))
            } else {
                List(model.stories) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title).font(.headline)
                            Text(s.skillTags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Text(s.narrative).font(.callout).lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editing = s }
                        Button(role: .destructive) { model.deleteStory(s.id) } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }
        .padding()
        .sheet(item: $editing) { story in StoryEditor(story: story).environmentObject(model) }
    }
}

struct StoryEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var story: Story
    @State private var tags = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(story.title.isEmpty ? "New story" : "Edit story").font(.headline)
                TextField("Title", text: $story.title)
                TextField("Skill tags (comma separated)", text: $tags)
                ForEach([("Situation", \Story.situation), ("Task", \Story.task), ("Action (what you did)", \Story.action), ("Result (only what you can show)", \Story.result), ("Lesson", \Story.lesson), ("Ownership (yours vs the team's)", \Story.ownership)], id: \.0) { label, keyPath in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { story[keyPath: keyPath] }, set: { story[keyPath: keyPath] = $0 })).frame(height: 56)
                    }
                }
                Text("Supporting claims").font(.caption).foregroundStyle(.secondary)
                ForEach(model.claims.filter { $0.state == .approved && $0.category != .contact }) { c in
                    Toggle(isOn: Binding(get: { story.claimRefs.contains(c.id) }, set: { on in if on { story.claimRefs.append(c.id) } else { story.claimRefs.removeAll { $0 == c.id } } })) { Text(c.text).lineLimit(1).font(.callout) }
                }
                HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { story.skillTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; model.saveStory(story); dismiss() }.keyboardShortcut(.defaultAction).disabled(story.title.isEmpty) }
            }.padding(20)
        }
        .frame(width: 600, height: 640)
        .onAppear { tags = story.skillTags.joined(separator: ", ") }
    }
}

struct TargetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: InterviewTarget?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Interview targets").font(.title2.bold()); Spacer(); Button("New target") { editing = InterviewTarget(role: "", company: "") } }
            Text("One target per application. Retrieval during a session is scoped to the selected target.").font(.callout).foregroundStyle(.secondary)
            if model.targets.isEmpty {
                ContentUnavailableView("No targets yet", systemImage: "target", description: Text("Add the role, company and job description."))
            } else {
                List(model.targets, selection: Binding(get: { model.selectedTargetID }, set: { model.selectTarget($0) })) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("\(t.role) · \(t.company)").font(.headline); Spacer(); Button("Edit") { editing = t }; Button(role: .destructive) { model.deleteTarget(t.id) } label: { Image(systemName: "trash") } }
                        Text("\(t.seniority.rawValue) · \(t.stage.rawValue) · \(t.language)").font(.caption).foregroundStyle(.secondary)
                        let matches = model.requirementMatches(for: t)
                        if !matches.isEmpty {
                            Text("\(matches.filter(\.covered).count) of \(matches.count) quoted requirements covered by approved evidence").font(.caption)
                            ForEach(matches.prefix(6), id: \.requirement) { m in
                                HStack(spacing: 6) { Image(systemName: m.covered ? "checkmark.circle.fill" : "circle").foregroundStyle(m.covered ? .green : .secondary); Text(m.requirement).font(.caption).lineLimit(1) }
                            }
                        }
                    }.tag(t.id).padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }
        .padding()
        .sheet(item: $editing) { t in TargetEditor(target: t).environmentObject(model) }
    }
}

struct TargetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var target: InterviewTarget
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.role.isEmpty ? "New target" : "Edit target").font(.headline)
            HStack { TextField("Role", text: $target.role); TextField("Company", text: $target.company) }
            HStack {
                Picker("Seniority", selection: $target.seniority) { ForEach(Seniority.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Stage", selection: $target.stage) { ForEach(InterviewStage.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Language", selection: $target.language) { Text("English (US)").tag("en-US"); Text("English (India)").tag("en-IN"); Text("English (UK)").tag("en-GB") }
            }
            Text("Job description (paste the text; requirements are quoted, not inferred)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $target.jobDescription).frame(minHeight: 200)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { model.saveTarget(target); dismiss() }.keyboardShortcut(.defaultAction).disabled(target.role.isEmpty) }
        }.padding(20).frame(width: 640, height: 480)
    }
}
