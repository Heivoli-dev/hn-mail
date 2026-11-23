<p align="center"><img src="packaging/icon-512.png" width="160" alt="HN Mail"></p>

# HN Mail

L'app Mac de Heivoli Network pour répondre aux mails reçus sur **contact@heivoli-network.fr** (et news@) avec des réponses toutes prêtes au style officiel.

- Liste des mails reçus sur contact@ et news@ : À traiter, Répondus, Tous, newsletter
- Notifications macOS, badge du Dock et icône dans la barre des menus
- Étiquette automatique : support logiciel, partenariat, données, remerciement, contestation
- 6 réponses prêtes modifiables, aperçu en direct (ordinateur / téléphone)
- Envoi par Brevo depuis contact@ ou news@, dans la même conversation

## Installer

Télécharge `HN-Mail.dmg` dans la dernière [Release](https://github.com/Heivoli-dev/hn-mail/releases/latest), glisse **HN Mail** dans Applications.
Premier lancement : clic droit sur l'app › **Ouvrir** (l'app n'est pas signée par Apple).

## Configurer (une seule fois)

Les mails reçus sur contact@ et news@ sont gardés par le Worker de heivoli-network.fr (90 jours) ; l'app les lit avec une clé privée.

1. Dans HN Mail › **Réglages** : **Créer une nouvelle clé**, puis **Copier**.
2. Dans le Terminal :
   ```
   cd ~/Desktop/HNfr/discord-worker
   npx wrangler secret put HN_MAIL_TOKEN
   ```
   et colle la clé.
3. Dans l'app : **Enregistrer**. Les mails s'affichent.
4. Ajoute ta clé **Brevo** (app.brevo.com › SMTP & API › Clés API) pour pouvoir répondre.

## Compiler

Chaque envoi sur `main` compile l'app (Apple Silicon + Intel) avec GitHub Actions et publie le `.dmg` en Release.
En local : `swift build -c release` (macOS 13+, Xcode 15+).
