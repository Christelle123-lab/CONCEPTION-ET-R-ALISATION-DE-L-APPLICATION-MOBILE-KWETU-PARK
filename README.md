# Kwetu Park

Application Flutter de réservation et de paiement de places de stationnement à
Goma (RDC). Interface entièrement en français, paiement Mobile Money via K-PAY.

## Fonctionnalités

- **Conducteur** : parcourir les parkings, réserver une place (créneau + date),
  demander un paiement Mobile Money, suivre ses réservations, prolonger un
  créneau, présenter son ticket QR.
- **Gestionnaire** : voir les réservations en attente, confirmer les paiements
  reçus au guichet, scanner les tickets QR à l'entrée/sortie.
- **Administrateur** : tableau de bord, gestion des parkings et des comptes du
  personnel (attribution/retrait des rôles), compteurs sur Firestore.

## Séparation des accès

Les responsabilités sont isolées par rôle. Un conducteur ne peut **jamais**
marquer son propre paiement comme reçu : il dépose une *demande* de paiement
(`paymentStatus: requested`) qu'un gestionnaire confirme au guichet
(`paymentStatus: paid`). En production, cette confirmation est aussi possible
par le webhook K-PAY (Cloud Function) sans intervention humaine.

| Rôle | Document source | Espace |
| --- | --- | --- |
| `driver` | `users/{uid}` | Accueil, réservation, ticket |
| `manager` | `managers/{uid}` | Réservations, parkings, scanner |
| `administrator` | `administrators/{uid}` | Tout ce qui précède + gestion des rôles |

Les règles Firestore (`firestore.rules`) bloquent côté client toute élévation
de rôle et toute auto-confirmation de paiement ; les Cloud Functions
(`functions/index.js`) garantissent la véracité des transactions K-PAY.

## Démarrage

```bash
flutter pub get
flutter run
```

La configuration Firebase (`google-services.json`, `GoogleService-Info.plist`,
Firebase web) n'est pas fournie : ajoutez celle de votre projet Firebase, en
particulier pour le projet `kwetu-park`, puis alimentez les comptes :

- Conducteur : s'inscrire dans l'application (le rôle `driver` est créé
  automatiquement).
- Gestionnaire/administrateur : créer `managers/{uid}` ou `administrators/{uid}`
  avec `active: true` (ou un document `users/{uid}` avec `role: 'manager'` /
  `role: 'administrator'`).

## Paiement (K-PAY)

1. **Mode démo** (par défaut) : le conducteur envoie une demande qui apparaît
   dans l'espace gestionnaire, qui confirme manuellement le paiement.
2. **Production** : passez `AppConfig.demoPayments` à `false`, déployez
   `functions/` avec les variables `KPAY_API_KEY`, `KPAY_MERCHANT_ID`,
   `KPAY_COUNTRY_CODE` (défaut `CD`) ; l'application appelle la Cloud Function
   `confirmPayment` (callable) et le webhook `https://<region>-kwetu-park.cloudfunctions.net/kpayWebhook`
   valide les confirmations K-PAY.

Les réglages suivants sont centralisés dans `lib/app_config.dart` :
`demoPayments`, `phoneCountryCode`, `confirmPaymentFunction`,
`requestKpayPaymentFunction`, `kpayApiBaseUrl`.

## Structure

```
lib/
  access/role_guard.dart        # garde de rôle + écran « accès refusé »
  repositories/                 # parks_repository, parking_repository
  services/notification_service.dart, payment_service.dart
  utils/app_units.dart          # tarif unique + formats (FC, date, heures)
  screens/                      # accueil, réservation, paiement, scanner,
                                # espaces gestionnaire et administrateur…
  app_config.dart
functions/                      # Cloud Functions K-PAY (callables + webhook)
firestore.rules                 # règles de sécurité par rôle
test/                           # tests unitaires (AppUnits, parks…)
```

## Tests

```bash
flutter test
```