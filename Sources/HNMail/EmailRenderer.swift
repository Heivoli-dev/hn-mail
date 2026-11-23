import Foundation

/// Fabrique le HTML du mail au style sobre « officiel » (même rendu que les mails du site).
enum EmailRenderer {
    static let site = "https://heivoli-network.fr"
    static let logo = "https://heivoli-network.fr/assets/hn-logo.png"
    static let font = "-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
    static let brand = "#5a4bd8"

    static func accentColor(_ accent: String) -> String {
        switch accent {
        case "warning": return "#d9730d"
        case "danger": return "#c4271b"
        case "success": return "#3d8a12"
        default: return brand
        }
    }

    static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func fill(_ text: String, firstName: String, subject: String) -> String {
        text.replacingOccurrences(of: "{prenom}", with: firstName).replacingOccurrences(of: "{objet}", with: subject)
    }

    /// Paragraphes séparés par une ligne vide, retours à la ligne conservés.
    static func paragraphs(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p style=\"margin:0 0 16px;font:15px/1.6 \(font);color:#3c3c43\">\(esc($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
    }

    static func render(template: ReplyTemplate, message: String, firstName: String, subject: String, buttonLabel: String) -> String {
        let color = accentColor(template.accent)
        let greeting = firstName.isEmpty ? "Bonjour," : "Bonjour \(esc(firstName)),"
        let rows = template.rows
            .map { (key: $0.key, value: fill($0.value, firstName: firstName, subject: subject)) }
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
        var table = ""
        if !rows.isEmpty {
            let lines = rows.enumerated().map { pair -> String in
                let row = pair.element
                let border = pair.offset > 0 ? "border-top:1px solid #e5e5ea;" : ""
                return "<tr><td style=\"padding:12px 0;\(border)width:120px;vertical-align:top;font:600 13px/1.5 \(font);color:#8e8e93\">\(esc(row.key))</td><td style=\"padding:12px 0;\(border)vertical-align:top;font:15px/1.5 \(font);color:#1c1c1e\">\(esc(row.value))</td></tr>"
            }.joined()
            table = "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin:4px 0 24px;border-top:2px solid #1c1c1e;border-bottom:1px solid #e5e5ea\">\(lines)</table>"
        }
        var button = ""
        if !buttonLabel.isEmpty, template.buttonURL.hasPrefix("https://") {
            button = "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin:8px 0 20px\"><tr><td style=\"background:\(color);border-radius:6px\"><a href=\"\(esc(template.buttonURL))\" style=\"display:inline-block;padding:13px 26px;font:600 15px/1 \(font);color:#ffffff;text-decoration:none;border-radius:6px\">\(esc(buttonLabel))</a></td></tr></table>"
        }
        let year = Calendar.current.component(.year, from: Date())
        return """
        <!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>\(esc(subject))</title></head>
        <body style="margin:0;padding:0;background:#f2f2f7">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f7"><tr><td align="center" style="padding:28px 12px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff">
        <tr><td style="height:6px;background:\(brand);font-size:0;line-height:0">&nbsp;</td></tr>
        <tr><td style="padding:22px 36px;border-bottom:1px solid #e5e5ea"><table role="presentation" cellpadding="0" cellspacing="0"><tr>
        <td style="vertical-align:middle"><a href="\(site)"><img src="\(logo)" width="40" height="40" alt="" style="display:block;border:0"></a></td>
        <td style="vertical-align:middle;padding-left:12px;font:700 16px/1 \(font);color:#1c1c1e">Heivoli Network</td></tr></table></td></tr>
        <tr><td style="padding:36px 36px 12px">
        <p style="margin:0 0 10px;font:700 12px/1 \(font);letter-spacing:.08em;text-transform:uppercase;color:\(color)">\(esc(template.eyebrow))</p>
        <h1 style="margin:0 0 22px;font:700 26px/1.25 \(font);letter-spacing:-.015em;color:#1c1c1e">\(esc(fill(template.title, firstName: firstName, subject: subject)))</h1>
        <p style="margin:0 0 16px;font:15px/1.6 \(font);color:#3c3c43">\(greeting)</p>
        \(paragraphs(fill(message, firstName: firstName, subject: subject)))
        \(table)\(button)
        <p style="margin:0 0 8px;font:15px/1.6 \(font);color:#3c3c43">À bientôt,<br><strong>L'équipe Heivoli Network</strong></p>
        </td></tr>
        <tr><td style="padding:24px 36px;background:#f7f7f9;border-top:1px solid #e5e5ea;font:12px/1.7 \(font);color:#8e8e93">
        <a href="\(site)" style="color:#3c3c43;text-decoration:none;font-weight:600">Site</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="\(site)/tickets.html" style="color:#3c3c43;text-decoration:none;font-weight:600">Aide</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="https://discord.gg/Z7kZ3WWZxw" style="color:#3c3c43;text-decoration:none;font-weight:600">Discord</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="\(site)/conditions.html#confidentialite" style="color:#3c3c43;text-decoration:none;font-weight:600">Confidentialité</a><br><br>
        Pour nous répondre, réponds simplement à ce mail.<br>
        Heivoli Network est un projet communautaire indépendant, non affilié à Nintendo.<br>© \(year) Heivoli Network
        </td></tr></table></td></tr></table></body></html>
        """
    }
}
