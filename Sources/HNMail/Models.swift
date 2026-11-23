import Foundation

/// Un mail reçu sur contact@ ou news@ (lu dans Gmail).
struct MailMessage: Identifiable, Hashable {
    let id: String
    let threadId: String
    let fromName: String
    let fromEmail: String
    let to: String
    let subject: String
    let date: Date
    let snippet: String
    let body: String
    let messageIdHeader: String
    let mailbox: Mailbox

    var firstName: String {
        let source = fromName.isEmpty ? fromEmail.components(separatedBy: "@").first ?? "" : fromName
        let word = source.split(separator: " ").first.map(String.init) ?? source
        return word.isEmpty ? "" : word.prefix(1).uppercased() + word.dropFirst()
    }

    var category: MailCategory { MailCategory.guess(subject: subject, body: body) }
}

enum Mailbox: String, CaseIterable, Identifiable {
    case contact = "contact@heivoli-network.fr"
    case news = "news@heivoli-network.fr"
    var id: String { rawValue }
}

enum Folder: Hashable, Identifiable {
    case todo, replied, all, news
    var id: String { title }
    var title: String {
        switch self {
        case .todo: return "À traiter"
        case .replied: return "Répondus"
        case .all: return "Tous les mails"
        case .news: return "Réponses à la newsletter"
        }
    }
    var symbol: String {
        switch self {
        case .todo: return "tray"
        case .replied: return "checkmark.circle"
        case .all: return "archivebox"
        case .news: return "newspaper"
        }
    }
}

/// Étiquette automatique d'un mail, devinée à partir de son contenu.
enum MailCategory: String {
    case software = "Support logiciel"
    case partnership = "Partenariat"
    case data = "Données"
    case thanks = "Remerciement"
    case appeal = "Contestation"
    case other = "Autre"

    var templateID: String {
        switch self {
        case .software: return "support"
        case .partnership: return "partenariat"
        case .data: return "donnees"
        case .thanks: return "merci"
        case .appeal: return "contestation"
        case .other: return "libre"
        }
    }

    static func guess(subject: String, body: String) -> MailCategory {
        let text = (subject + " " + body).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["ban", "banni", "contest", "sanction", "avertissement"]) { return .appeal }
        if has(["supprimer mon compte", "suppression", "mes données", "rgpd", "données personnelles", "effacer"]) { return .data }
        if has(["partenariat", "partenaire", "collaboration", "sponsor", "tournoi"]) { return .partnership }
        if has(["screenlink", "theme studio", "thème", "hn screen", "3dsx", "cia", "bug", "installer", "marche pas", "fonctionne pas", "erreur"]) { return .software }
        if has(["merci", "bravo", "génial", "trop bien", "super"]) { return .thanks }
        return .other
    }
}

/// Une ligne du tableau d'informations dans le mail.
struct DetailRow: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

/// Une réponse prête. {prenom} et {objet} sont remplacés automatiquement.
struct ReplyTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var subtitle: String
    var eyebrow: String
    var title: String
    var message: String
    var rows: [DetailRow]
    var buttonLabel: String
    var buttonURL: String
    var accent: String // brand, warning, danger, success

    static let defaults: [ReplyTemplate] = [
        ReplyTemplate(id: "support", name: "Support logiciel", subtitle: "Aide + guide", eyebrow: "Support logiciel",
                      title: "Réponse à ta demande",
                      message: "Merci pour ton message. Voici ce que tu peux essayer :\n\n",
                      rows: [DetailRow(key: "Ta demande", value: "{objet}"), DetailRow(key: "Guides", value: "heivoli-network.fr/logiciels.html")],
                      buttonLabel: "Voir les logiciels et guides", buttonURL: "https://heivoli-network.fr/logiciels.html", accent: "brand"),
        ReplyTemplate(id: "partenariat", name: "Partenariat", subtitle: "Merci / suite", eyebrow: "Partenariat",
                      title: "Merci pour ta proposition",
                      message: "Merci d'avoir pensé à Heivoli Network ! Nous avons bien reçu ta proposition et nous revenons vers toi très vite.",
                      rows: [DetailRow(key: "Proposition", value: "{objet}"), DetailRow(key: "Suite", value: "Réponse sous quelques jours")],
                      buttonLabel: "Rejoindre le Discord", buttonURL: "https://discord.gg/Z7kZ3WWZxw", accent: "brand"),
        ReplyTemplate(id: "donnees", name: "Données perso", subtitle: "Suppression RGPD", eyebrow: "Données personnelles",
                      title: "Ta demande concernant tes données",
                      message: "Nous avons bien reçu ta demande. Ton compte et les données associées seront supprimés sous 30 jours maximum. Tu recevras une confirmation une fois l'opération terminée.",
                      rows: [DetailRow(key: "Demande", value: "{objet}"), DetailRow(key: "Délai", value: "30 jours maximum")],
                      buttonLabel: "Politique de confidentialité", buttonURL: "https://heivoli-network.fr/conditions.html#confidentialite", accent: "brand"),
        ReplyTemplate(id: "merci", name: "Remerciement", subtitle: "Message gentil", eyebrow: "Merci",
                      title: "Merci pour ton message !",
                      message: "Ton message nous a fait super plaisir, merci ! C'est grâce à des retours comme le tien que la communauté avance.",
                      rows: [],
                      buttonLabel: "Découvrir les nouveautés", buttonURL: "https://heivoli-network.fr", accent: "success"),
        ReplyTemplate(id: "contestation", name: "Contestation", subtitle: "Acceptée / refusée", eyebrow: "Modération",
                      title: "Réponse à ta contestation",
                      message: "La modération a examiné ta contestation.\n\nDécision : ",
                      rows: [DetailRow(key: "Concerne", value: "{objet}")],
                      buttonLabel: "Relire les règles", buttonURL: "https://heivoli-network.fr/conditions.html#regles", accent: "warning"),
        ReplyTemplate(id: "libre", name: "Libre", subtitle: "Sans modèle", eyebrow: "Heivoli Network",
                      title: "Réponse à ton message",
                      message: "",
                      rows: [],
                      buttonLabel: "", buttonURL: "", accent: "brand"),
    ]
}
