import AppKit
import SwiftUI
import WebKit

let brandColor = Color(red: 0x5a / 255, green: 0x4b / 255, blue: 0xd8 / 255)

// MARK: - Fenêtre principale

struct ContentView: View {
    @EnvironmentObject var store: MailStore
    @Binding var showNewMail: Bool
    @State private var showTemplates = false
    @State private var showSettings = false

    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 0) {
            if updater.state == .available && !updater.dismissed, let release = updater.latest {
                UpdateBanner(release: release)
            } else if updater.state == .downloading || updater.state == .installing {
                UpdateBanner(release: updater.latest)
            }
            mainSplit
        }
    }

    private var mainSplit: some View {
        NavigationSplitView {
            SidebarView(showTemplates: $showTemplates)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if store.folder == .sent {
                if let mail = store.selectedSent {
                    SentMailView(mail: mail).id(mail.id)
                } else {
                    Text("Choisis un mail envoyé à gauche.").foregroundStyle(.secondary)
                }
            } else if let message = store.selected {
                ReplyView(message: message).id(message.id)
            } else {
                EmptyStateView()
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Rechercher un mail")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                    .disabled(store.loading)
                Button { showNewMail = true } label: { Label("Nouveau", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showNewMail) { NewMailView().environmentObject(store) }
        .sheet(isPresented: $showTemplates) { TemplateManagerView().environmentObject(store) }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Réglages").font(.title2.bold())
                    Spacer()
                    Button("Terminé") { showSettings = false }.keyboardShortcut(.defaultAction)
                }
                .padding(16)
                Divider()
                SettingsView().environmentObject(store).frame(maxHeight: .infinity)
            }
            .frame(width: 600, height: 640)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showSettings = true }
        .onChange(of: store.folder) { _ in
            store.selectedID = store.visible.first?.id
            store.selectedSentID = store.visibleSent.first?.id
        }
    }
}

/// Bandeau « nouvelle version disponible ».
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared
    let release: Updater.Release?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(brandColor)
            if updater.state == .downloading {
                ProgressView().controlSize(.small)
                Text("Téléchargement de la mise à jour…")
            } else if updater.state == .installing {
                ProgressView().controlSize(.small)
                Text("Installation… HN Mail va redémarrer.")
            } else {
                Text("HN Mail \(release?.version ?? "") est disponible").fontWeight(.semibold)
                Text("(tu as la \(updater.currentVersion))").foregroundStyle(.secondary)
                Spacer()
                Button("Plus tard") { updater.dismissed = true }
                Button("Installer et relancer") { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent).tint(brandColor)
            }
            if updater.state != .available { Spacer() }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(brandColor.opacity(0.1))
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: MailStore
    @Binding var showTemplates: Bool

    var body: some View {
        List(selection: Binding<Folder?>(get: { store.folder }, set: { if let value = $0 { store.folder = value } })) {
            Section("contact@") {
                ForEach([Folder.todo, .replied, .all, .sent]) { folder in
                    Label(folder.title, systemImage: folder.symbol).badge(store.count(folder)).tag(folder)
                }
            }
            Section("news@") {
                Label(Folder.news.title, systemImage: Folder.news.symbol).badge(store.count(.news)).tag(Folder.news)
            }
            Section("Réponses prêtes") {
                Button { showTemplates = true } label: { Label("Gérer les templates", systemImage: "square.grid.2x2") }
                    .buttonStyle(.plain)
                Button { openSettingsWindow() } label: { Label("Réglages", systemImage: "gearshape") }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle().fill(store.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(store.inboxConfigured ? "Boîte contact@ connectée" : "Clé HN Mail manquante")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
        }
    }
}

struct MessageListView: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        if store.folder == .sent { SentListView() } else { receivedList }
    }

    private var receivedList: some View {
        List(store.visible, selection: $store.selectedID) { message in
            MessageRow(message: message, replied: store.isReplied(message), repliedLabel: store.repliedLabel(message)).tag(message.id)
        }
        .listStyle(.inset)
        .overlay {
            if store.loading && store.messages.isEmpty {
                ProgressView("Chargement des mails…")
            } else if let error = store.error, store.messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Ouvrir les Réglages") { openSettingsWindow() }
                }.padding()
            } else if store.visible.isEmpty {
                Text(store.folder == .todo ? "Tout est traité ✨" : "Aucun mail ici").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.folder.title)
    }
}

struct SentListView: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        List(store.visibleSent, selection: $store.selectedSentID) { mail in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("À : \(mail.toLabel)").font(.headline).lineLimit(1)
                    Spacer()
                    Text(mail.sentAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(mail.subject).fontWeight(.semibold).lineLimit(1)
                Text(mail.snippet).foregroundStyle(.secondary).lineLimit(2)
                Text("Envoyé par \(mail.by)\(mail.synced ? "" : " · pas encore partagé")")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(brandColor.opacity(0.12)))
                    .foregroundStyle(brandColor)
            }
            .padding(.vertical, 4)
            .tag(mail.id)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                if store.importingBrevo { ProgressView().controlSize(.small) }
                Text(store.brevoImportStatus.isEmpty ? "Mails envoyés avant la 1.4 ?" : store.brevoImportStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Récupérer depuis Brevo") { Task { await store.importFromBrevo() } }
                    .controlSize(.small)
                    .disabled(store.importingBrevo)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .overlay {
            if store.visibleSent.isEmpty && !store.importingBrevo {
                Text(store.search.isEmpty ? "Aucun mail envoyé pour l'instant" : "Aucun résultat").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Folder.sent.title)
    }
}

/// Un mail envoyé, affiché exactement comme la personne l'a reçu.
struct SentMailView: View {
    let mail: SentMail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mail.subject).font(.title2.bold()).textSelection(.enabled)
                Text("À : \(mail.toName.isEmpty ? mail.toEmail : "\(mail.toName) <\(mail.toEmail)>")").textSelection(.enabled)
                Text("Envoyé depuis \(mail.fromAddress) par \(mail.by), le \(mail.sentAt.formatted(date: .long, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if mail.html.isEmpty {
                ScrollView { Text(mail.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
            } else {
                HTMLView(html: mail.html)
            }
        }
    }
}

struct MessageRow: View {
    let message: MailMessage
    let replied: Bool
    var repliedLabel = "Répondu"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.fromName.isEmpty ? message.fromEmail : message.fromName).font(.headline).lineLimit(1)
                Spacer()
                Text(message.date, format: Date.FormatStyle(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(message.subject).fontWeight(.semibold).lineLimit(1)
            Text(message.snippet).foregroundStyle(.secondary).lineLimit(2)
            Text(replied ? repliedLabel : message.category.rawValue)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(replied ? Color.green.opacity(0.15) : brandColor.opacity(0.12)))
                .foregroundStyle(replied ? Color.green : brandColor)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: MailStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open").font(.system(size: 44)).foregroundStyle(brandColor)
            Text("HN Mail").font(.title.bold())
            if store.isReady {
                Text("Choisis un mail à gauche pour y répondre.").foregroundStyle(.secondary)
            } else {
                Text("Pour commencer, connecte Gmail et ajoute ta clé Brevo.").foregroundStyle(.secondary)
                Button("Ouvrir les Réglages") { openSettingsWindow() }.buttonStyle(.borderedProminent).tint(brandColor)
            }
        }
    }
}

// MARK: - Lecture + réponse

struct ReplyView: View {
    @EnvironmentObject var store: MailStore
    let message: MailMessage

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.subject).font(.title2.bold()).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Circle().fill(Color.yellow.opacity(0.6)).frame(width: 32, height: 32)
                            .overlay(Text(String(message.firstName.prefix(1))).bold())
                        VStack(alignment: .leading) {
                            Text(message.fromName.isEmpty ? message.fromEmail : message.fromName).bold()
                            Text("\(message.fromEmail) · à \(message.mailbox.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(store.isReplied(message) ? "Remettre à traiter" : "Marquer comme traité") {
                            store.markReplied(message, !store.isReplied(message))
                        }
                    }
                    Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !message.attachments.isEmpty {
                        Label("Pièces jointes : \(message.attachments.joined(separator: ", ")) (visibles dans ton Gmail)", systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.sentReplies(to: message)) { reply in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Réponse envoyée par \(reply.by) · \(reply.sentAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "paperplane.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(brandColor)
                            Text(reply.text).font(.callout).textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(brandColor.opacity(0.07)))
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 140, idealHeight: 220)

            ComposerView(target: .init(message: message)) { store.markReplied(message) }
                .frame(minHeight: 380)
        }
    }
}

/// À qui on écrit (réponse à un mail ou nouveau mail).
struct Recipient {
    var email: String
    var name: String
    var firstName: String
    var subject: String
    var originalSubject: String
    var inReplyTo: String?
    var mailbox: Mailbox
    var suggestedTemplate: String
    var receivedBody = ""
    var inboxID = ""

    init(message: MailMessage) {
        receivedBody = message.body
        inboxID = message.id
        email = message.fromEmail
        name = message.fromName
        firstName = message.firstName
        originalSubject = message.subject
        subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        inReplyTo = message.messageIdHeader
        mailbox = .contact
        suggestedTemplate = message.category.templateID
    }

    init(email: String = "", name: String = "", subject: String = "") {
        self.email = email
        self.name = name
        firstName = name.split(separator: " ").first.map(String.init) ?? ""
        self.subject = subject
        originalSubject = subject
        inReplyTo = nil
        mailbox = .contact
        suggestedTemplate = "libre"
    }
}

struct ComposerView: View {
    @EnvironmentObject var store: MailStore
    @State var target: Recipient
    var editableRecipient = false
    var onSent: () -> Void

    @State private var templateID = ""
    @State private var text = ""
    @State private var buttonLabel = ""
    @State private var sending = false
    @State private var status = ""
    @State private var statusIsError = false
    @State private var phonePreview = false
    @State private var aiInstruction = ""
    @State private var aiBusy = ""
    @State private var aiStatus = ""
    @State private var aiStatusIsError = false
    @State private var textBeforeAI: String?
    @State private var correctedForSend = ""
    @AppStorage("autoCorrect") private var autoCorrect = true

    init(target: Recipient, editableRecipient: Bool = false, onSent: @escaping () -> Void) {
        _target = State(initialValue: target)
        self.editableRecipient = editableRecipient
        self.onSent = onSent
    }

    private var template: ReplyTemplate { store.template(templateID) }
    private var html: String {
        EmailRenderer.render(template: template, message: text, firstName: target.firstName, subject: target.originalSubject, buttonLabel: buttonLabel)
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if editableRecipient {
                        LabeledField("Destinataire") { TextField("adresse@exemple.fr", text: $target.email) }
                        LabeledField("Prénom (pour « Bonjour … »)") { TextField("Facultatif", text: $target.firstName) }
                        Picker("Envoyer depuis", selection: $target.mailbox) {
                            ForEach(Mailbox.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Text("Réponse prête").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(store.templates) { item in
                            Button { apply(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).fontWeight(.semibold)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.id == templateID ? brandColor : Color.gray.opacity(0.3), lineWidth: item.id == templateID ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    LabeledField("Objet") {
                        TextField("Objet", text: $target.subject)
                            .onChange(of: target.subject) { value in if editableRecipient { target.originalSubject = value } }
                    }
                    LabeledField("Ton message") {
                        TextEditor(text: $text).font(.body).frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    }
                    aiControls
                    LabeledField("Texte du bouton (vide = pas de bouton)") { TextField("Bouton", text: $buttonLabel) }
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            if sending { ProgressView().controlSize(.small) }
                            Text(sending ? "Envoi…" : "Envoyer depuis \(target.mailbox == .news ? "news@" : "contact@")")
                            Image(systemName: "paperplane.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(brandColor).controlSize(.large)
                    .disabled(sending || target.email.isEmpty || target.subject.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    if !status.isEmpty {
                        Text(status).font(.callout).foregroundStyle(statusIsError ? Color.red : Color.green)
                    }
                    Text("Envoyé avec Brevo, dans la même conversation que le mail reçu. ⌘↩ pour envoyer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)

            VStack(spacing: 8) {
                HStack {
                    Text("APERÇU DU MAIL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $phonePreview) {
                        Text("Ordinateur").tag(false)
                        Text("Téléphone").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 200)
                }
                HTMLView(html: html)
                    .frame(maxWidth: phonePreview ? 380 : .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: phonePreview ? 24 : 4))
                    .overlay(RoundedRectangle(cornerRadius: phonePreview ? 24 : 4).stroke(Color.gray.opacity(0.25)))
            }
            .padding(14)
            .frame(minWidth: 380)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { if templateID.isEmpty { apply(store.template(target.suggestedTemplate)) } }
    }

    // MARK: IA

    private var aiControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Consigne pour l'IA (facultatif) : ex. « refuse poliment »", text: $aiInstruction)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button { Task { await aiDraft() } } label: {
                    HStack(spacing: 4) {
                        if aiBusy == "draft" { ProgressView().controlSize(.small) }
                        Text("✨ Proposer une réponse")
                    }
                }
                .help("L'IA lit le mail reçu et écrit une réponse à partir du modèle choisi.")
                Button { Task { await aiCorrect() } } label: {
                    HStack(spacing: 4) {
                        if aiBusy == "correct" { ProgressView().controlSize(.small) }
                        Text("Corriger")
                    }
                }
                .help("Corrige l'orthographe et la grammaire sans changer ton texte.")
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if textBeforeAI != nil {
                    Button("Annuler") { if let old = textBeforeAI { text = old; textBeforeAI = nil; aiStatus = "" } }
                        .help("Revenir au texte d'avant l'IA.")
                }
            }
            .disabled(!aiBusy.isEmpty || sending)
            if !aiStatus.isEmpty {
                Text(aiStatus).font(.caption).foregroundStyle(aiStatusIsError ? Color.red : Color.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(brandColor.opacity(0.06)))
    }

    private func aiDraft() async {
        aiBusy = "draft"; aiStatus = "L'IA écrit…"; aiStatusIsError = false
        defer { aiBusy = "" }
        do {
            let result = try await AIAPI().draft(mailFrom: target.name.isEmpty ? target.email : target.name, subject: target.originalSubject,
                                                 body: target.receivedBody, template: template, current: text, instruction: aiInstruction)
            textBeforeAI = text
            text = result
            aiStatus = "Réponse proposée par l'IA : relis-la avant d'envoyer."
        } catch {
            aiStatus = error.localizedDescription; aiStatusIsError = true
        }
    }

    private func aiCorrect() async {
        aiBusy = "correct"; aiStatus = "Correction…"; aiStatusIsError = false
        defer { aiBusy = "" }
        do {
            let result = try await AIAPI().correct(text)
            if result == text {
                aiStatus = "Aucune faute trouvée ✓"
            } else {
                textBeforeAI = text
                text = result
                aiStatus = "Texte corrigé ✓"
            }
            correctedForSend = text
        } catch {
            aiStatus = error.localizedDescription; aiStatusIsError = true
        }
    }

    private func apply(_ item: ReplyTemplate) {
        templateID = item.id
        text = EmailRenderer.fill(item.message, firstName: target.firstName, subject: target.originalSubject)
        buttonLabel = item.buttonLabel
    }

    private func send() async {
        sending = true
        status = ""
        defer { sending = false }
        let email = target.email.trimmingCharacters(in: .whitespaces)
        guard email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else {
            status = "Adresse du destinataire invalide."; statusIsError = true; return
        }
        // Correcteur auto : on corrige avant le premier envoi ; si l'IA change quelque chose, on montre le texte avant d'envoyer.
        if autoCorrect && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && correctedForSend != text {
            status = "Correction avant l'envoi…"; statusIsError = false
            if let result = try? await AIAPI().correct(text) {
                correctedForSend = result
                if result != text {
                    textBeforeAI = text
                    text = result
                    status = "J'ai corrigé quelques fautes : vérifie l'aperçu puis clique à nouveau sur Envoyer."
                    statusIsError = false
                    return
                }
            }
            status = ""
        }
        do {
            try await store.brevo.send(from: target.mailbox, toEmail: email, toName: target.name, subject: target.subject, html: html, inReplyTo: target.inReplyTo)
            status = "Envoyé à \(email) ✓"
            statusIsError = false
            store.recordSent(SentMail(id: UUID().uuidString, mailbox: target.mailbox == .news ? "news" : "contact", toEmail: email,
                                      toName: target.name, subject: target.subject, text: text, html: html, sentAt: Date(),
                                      by: store.teamName, inboxId: target.inboxID, template: templateID))
            onSent()
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// Affiche le HTML du mail (aperçu en direct).
struct HTMLView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.last != html {
            context.coordinator.last = html
            view.loadHTMLString(html, baseURL: URL(string: "https://heivoli-network.fr"))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}

// MARK: - Nouveau mail

struct NewMailView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nouveau mail").font(.title2.bold())
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ComposerView(target: Recipient(), editableRecipient: true) {}
        }
        .frame(width: 1000, height: 700)
    }
}

// MARK: - Templates

struct TemplateManagerView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Réponses prêtes").font(.title2.bold())
                Spacer()
                Button("Ajouter") {
                    let item = ReplyTemplate(id: UUID().uuidString, name: "Nouveau modèle", subtitle: "", eyebrow: "Heivoli Network",
                                             title: "Réponse à ton message", message: "", rows: [], buttonLabel: "", buttonURL: "", accent: "brand")
                    store.templates.insert(item, at: max(0, store.templates.count - 1))
                    selection = item.id
                    store.saveTemplates()
                }
                Button("Rétablir les modèles d'origine") { store.resetTemplates(); selection = store.templates.first?.id }
                Button("Terminé") { store.saveTemplates(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            HSplitView {
                List(store.templates, selection: $selection) { item in
                    VStack(alignment: .leading) {
                        Text(item.name).fontWeight(.semibold)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }
                .frame(minWidth: 200, maxWidth: 240)
                if let index = store.templates.firstIndex(where: { $0.id == selection }) {
                    TemplateEditor(template: $store.templates[index]) {
                        store.templates.remove(at: index)
                        selection = store.templates.first?.id
                        store.saveTemplates()
                    }
                } else {
                    Text("Choisis un modèle à gauche.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 860, height: 640)
        .onAppear { selection = store.templates.first?.id }
        .onDisappear { store.saveTemplates() }
    }
}

struct TemplateEditor: View {
    @Binding var template: ReplyTemplate
    var onDelete: () -> Void

    var body: some View {
        Form {
            Section("Dans l'app") {
                TextField("Nom", text: $template.name)
                TextField("Sous-titre", text: $template.subtitle)
            }
            Section("Dans le mail") {
                TextField("Petit titre coloré", text: $template.eyebrow)
                TextField("Titre", text: $template.title)
                Picker("Couleur", selection: $template.accent) {
                    Text("Violet").tag("brand")
                    Text("Orange").tag("warning")
                    Text("Rouge").tag("danger")
                    Text("Vert").tag("success")
                }
                VStack(alignment: .leading) {
                    Text("Message par défaut")
                    TextEditor(text: $template.message).frame(minHeight: 90)
                }
                Text("{prenom} et {objet} sont remplacés automatiquement. Une ligne vide crée un nouveau paragraphe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tableau d'informations") {
                ForEach($template.rows) { $row in
                    HStack {
                        TextField("Intitulé", text: $row.key).frame(width: 140)
                        TextField("Valeur", text: $row.value)
                        Button(role: .destructive) { template.rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Ajouter une ligne") { template.rows.append(DetailRow(key: "", value: "")) }
            }
            Section("Bouton") {
                TextField("Texte du bouton", text: $template.buttonLabel)
                TextField("Lien (https://…)", text: $template.buttonURL)
            }
            Section {
                Button("Supprimer ce modèle", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @EnvironmentObject var store: MailStore
    @State private var brevoKey = ""
    @State private var brevoSaved = Keychain.get("brevoApiKey") != nil
    @State private var inboxKey = ""
    @State private var editingKey = false
    @State private var showKey = false
    @AppStorage("pollMinutes") private var pollMinutes = 2
    @AppStorage("teamName") private var teamName = ""
    @AppStorage("autoCorrect") private var autoCorrect = true

    var body: some View {
        Form {
            Section {
                if store.inboxConfigured && !editingKey {
                    HStack {
                        Label("Clé HN Mail enregistrée", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Changer") { editingKey = true; inboxKey = "" }
                    }
                } else {
                    HStack {
                        SecureField("Colle ta clé HN Mail", text: $inboxKey)
                        Button("Enregistrer") {
                            let key = inboxKey
                            Task { await store.saveInboxKey(key); editingKey = false; inboxKey = "" }
                        }
                        .disabled(inboxKey.trimmingCharacters(in: .whitespaces).count < 24)
                    }
                    HStack {
                        Button("Créer une nouvelle clé") { inboxKey = InboxAPI.generateKey(); showKey = true }
                        if showKey && !inboxKey.isEmpty {
                            Button("Copier") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(inboxKey, forType: .string)
                            }
                        }
                    }
                    if showKey && !inboxKey.isEmpty {
                        Text(inboxKey).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Boîte de réception (contact@ et news@)")
            } footer: {
                Text("Clique sur « Créer une nouvelle clé », copie-la, puis installe-la sur le serveur dans le Terminal : cd ~/Desktop/HNfr/discord-worker puis npx wrangler secret put HN_MAIL_TOKEN (colle la clé). Reviens ici et clique sur Enregistrer.")
            }

            Section {
                if brevoSaved {
                    HStack {
                        Label("Clé enregistrée dans le trousseau", systemImage: "key.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Remplacer") { Keychain.set("brevoApiKey", nil); brevoSaved = false }
                    }
                } else {
                    HStack {
                        SecureField("xkeysib-…", text: $brevoKey)
                        Button("Enregistrer") {
                            Keychain.set("brevoApiKey", brevoKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            brevoKey = ""
                            brevoSaved = true
                        }
                        .disabled(brevoKey.count < 20)
                    }
                }
            } header: {
                Text("Brevo (envoi des réponses)")
            } footer: {
                Text("Crée une clé dédiée à HN Mail sur app.brevo.com › SMTP & API › Clés API.")
            }

            Section {
                TextField("Ton prénom", text: $teamName, prompt: Text(Host.current().localizedName ?? "Mac"))
            } header: {
                Text("Équipe")
            } footer: {
                Text("Affiché aux autres membres de l'équipe : « Répondu par … ». L'état « Répondu » est partagé entre toutes les apps HN Mail.")
            }

            Section {
                Toggle("Notifier les nouveaux mails", isOn: Binding(get: { Notifier.shared.enabled }, set: { Notifier.shared.enabled = $0 }))
                Picker("Vérifier les mails", selection: $pollMinutes) {
                    Text("Toutes les minutes").tag(1)
                    Text("Toutes les 2 minutes").tag(2)
                    Text("Toutes les 5 minutes").tag(5)
                    Text("Toutes les 15 minutes").tag(15)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Les notifications s'affichent comme celles de Discord. HN Mail reste dans la barre des menus quand tu fermes la fenêtre. Pour les autoriser : Réglages Système › Notifications › HN Mail.")
            }

            AISettingsSection()

            UpdateSettingsSection()

            if let error = store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct AISettingsSection: View {
    @AppStorage("aiEngine") private var engine = AIEngine.claude.rawValue
    @AppStorage("ollamaModel") private var ollamaModel = "mistral"
    @AppStorage("autoCorrect") private var autoCorrect = true
    @State private var ollamaStatus = ""

    var body: some View {
        Section {
            Picker("Moteur IA", selection: $engine) {
                ForEach(AIEngine.allCases) { item in Text(item.label).tag(item.rawValue) }
            }
            switch AIEngine(rawValue: engine) ?? .claude {
            case .claude:
                Text("Le plus doué pour écrire. Passe par ton Worker et utilise le crédit de ton compte Anthropic (environ 1 centime par réponse).")
                    .font(.caption).foregroundStyle(.secondary)
            case .apple:
                let state = AppleAI.status
                Label(state.text, systemImage: state.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.ok ? Color.green : Color.orange)
                Text("Tourne sur ton Mac, sans Internet et gratuitement. Très bien pour corriger ; pour écrire, c'est plus simple que Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            case .ollama:
                HStack {
                    TextField("Modèle Ollama", text: $ollamaModel)
                    Button("Tester") {
                        Task {
                            do {
                                let models = try await OllamaAI.installedModels()
                                let wanted = ollamaModel.trimmingCharacters(in: .whitespaces)
                                if models.contains(where: { $0 == wanted || $0.hasPrefix(wanted + ":") }) { ollamaStatus = "✅ Ollama est prêt avec « \(wanted) »." }
                                else if models.isEmpty { ollamaStatus = "Aucun modèle installé. Dans le Terminal : ollama pull \(wanted)" }
                                else { ollamaStatus = "« \(wanted) » n'est pas installé. Modèles présents : \(models.joined(separator: ", "))" }
                            } catch { ollamaStatus = error.localizedDescription }
                        }
                    }
                }
                if !ollamaStatus.isEmpty { Text(ollamaStatus).font(.caption) }
                Text("Installe l'app gratuite Ollama (ollama.com), puis dans le Terminal : ollama pull mistral. Tourne sur ton Mac, sans Internet et gratuitement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Corriger automatiquement avant chaque envoi", isOn: $autoCorrect)
        } header: {
            Text("IA")
        } footer: {
            Text("Dans la réponse : « ✨ Proposer une réponse » écrit un brouillon à partir du mail reçu et du modèle choisi, « Corriger » enlève les fautes.")
        }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            HStack {
                Text("Version installée : \(updater.currentVersion) (build \(updater.currentBuild))")
                Spacer()
                Button(updater.state == .checking ? "Vérification…" : "Rechercher une mise à jour") {
                    Task { await updater.check(silent: false) }
                }
                .disabled(updater.busy)
            }
            switch updater.state {
            case .upToDate:
                Label("HN Mail est à jour.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available:
                HStack {
                    Label("Version \(updater.latest?.version ?? "") disponible", systemImage: "arrow.down.circle.fill").foregroundStyle(brandColor)
                    Spacer()
                    Button("Installer et relancer") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent).tint(brandColor)
                }
            case .downloading:
                Label("Téléchargement…", systemImage: "arrow.down.circle")
            case .installing:
                Label("Installation… HN Mail va redémarrer.", systemImage: "gearshape.2")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            default:
                EmptyView()
            }
            Toggle("Rechercher les mises à jour automatiquement", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
        } header: {
            Text("Mises à jour")
        } footer: {
            Text("HN Mail télécharge la dernière version publiée sur GitHub, vérifie le fichier, remplace l'app et redémarre.")
        }
    }
}

// MARK: - Barre des menus

struct MenuBarContent: View {
    @EnvironmentObject var store: MailStore
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        let todo = store.messages.filter { $0.mailbox == .contact && !store.isReplied($0) }
        Text(todo.isEmpty ? "Aucun mail à traiter" : "\(todo.count) mail\(todo.count > 1 ? "s" : "") à traiter")
        Divider()
        ForEach(todo.prefix(6)) { message in
            Button("\(message.fromName.isEmpty ? message.fromEmail : message.fromName) — \(message.subject)") { open(message.id) }
        }
        if !todo.isEmpty { Divider() }
        if updater.state == .available {
            Button("Installer la mise à jour \(updater.latest?.version ?? "")…") { Task { await updater.install() } }
            Divider()
        }
        Button("Ouvrir HN Mail") { open(nil) }
        Button("Actualiser") { Task { await store.refresh() } }
        Button("Réglages…") { openSettingsWindow() }
        Divider()
        Button("Quitter HN Mail") { NSApp.terminate(nil) }
    }

    private func open(_ id: String?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        if let id {
            store.folder = .todo
            store.search = ""
            store.selectedID = id
        }
    }
}
