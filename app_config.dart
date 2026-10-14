/// Configuration centrale de Kwetu Park.
///
/// Le paiement est volontairement piloté par une configuration unique :
/// la démonstration locale simule l'enregistrement pour rester utilisable
/// sans serveur, tandis que la mise en production appelle la Cloud Function
/// `confirmPayment` qui vérifie K-PAY avant de valider toute réservation.
abstract final class AppConfig {
  /// `true` : le paiement est simulé côté application (démo hors-ligne).
  /// `false` : le paiement passe par la Cloud Function `confirmPayment`
  /// qui interroge l'API K-PAY et marque la réservation payée côté serveur.
  ///
  /// Veillez à déployer les règles Firestore sécurisées (`firestore.rules`)
  /// en production : un conducteur ne peut jamais se marquer payé lui-même,
  /// avec ou sans ce drapeau.
  static const bool demoPayments = true;

  /// Base de l'API de paiement mobile K-PAY (kpay.site).
  static const String kpayApiBaseUrl = 'https://api.k-pay.app';

  /// Nom de la Cloud Function appelable qui initialise le paiement.
  static const String kpayRequestFunction = 'requestKpayPayment';

  /// Nom de la Cloud Function appelable qui confirme un paiement reçu.
  static const String confirmPaymentFunction = 'confirmPayment';

  /// Indicatif utilisé pour les numéros Mobile Money.
  static const String phoneCountryCode = '+243';
}