<p align="center"><img src="packaging/icon-512.png" width="160" alt="HN Mail"></p>

# HN Mail

L'app Mac de Heivoli Network pour répondre aux mails reçus sur **contact@heivoli-network.fr** (et news@) avec des réponses toutes prêtes au style officiel.

- Liste des mails reçus (lus dans Gmail, en lecture seule) : À traiter, Répondus, Tous, newsletter
- Étiquette automatique : support logiciel, partenariat, données, remerciement, contestation
- 6 réponses prêtes modifiables, aperçu en direct (ordinateur / téléphone)
- Envoi par Brevo depuis contact@ ou news@, dans la même conversation

## Installer

Télécharge `HN-Mail.dmg` dans la dernière [Release](https://github.com/Heivoli-dev/hn-mail/releases/latest), glisse **HN Mail** dans Applications.
Premier lancement : clic droit sur l'app › **Ouvrir** (l'app n'est pas signée par Apple).

## Configurer (une seule fois)

### 1. Accès Gmail (console Google)

Dans la [console Google Cloud](https://console.cloud.google.com/), projet **heivoli-network-408f3** :

1. **API et services › Bibliothèque** : active **Gmail API**.
2. **API et services › Écran de consentement OAuth** : type **Externe**, nom « HN Mail », ton adresse en contact.
   Ajoute le champ d'application `gmail.readonly`, et ajoute ton adresse Gmail dans **Utilisateurs test**.
   Puis **Publier l'application** (sinon la connexion expire au bout de 7 jours ; Google affichera « application non validée » : clique sur *Paramètres avancés › Accéder à HN Mail*).
3. **API et services › Identifiants › Créer des identifiants › ID client OAuth** : type **Application de bureau**, nom « HN Mail ».
4. Dans HN Mail › **Réglages** (⌘,), colle l'**ID client** et le **code secret**, puis **Connecter Gmail**.

### 2. Clé Brevo

Sur [app.brevo.com › SMTP & API › Clés API](https://app.brevo.com/settings/keys/api), crée une clé « hn-mail » et colle-la dans les Réglages. Elle est rangée dans le trousseau du Mac.

## Compiler

Chaque envoi sur `main` compile l'app (Apple Silicon + Intel) avec GitHub Actions et publie le `.dmg` en Release.
En local : `swift build -c release` (macOS 13+, Xcode 15+).
