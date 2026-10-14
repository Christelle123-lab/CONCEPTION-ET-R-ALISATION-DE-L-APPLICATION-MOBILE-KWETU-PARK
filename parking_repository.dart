import 'package:firebase_auth/firebase_auth.dart';

import 'services/api_client.dart';
import 'utils/app_units.dart';

/// Etats synchronises des places de stationnement.
enum ParkingSpotStatus {
  available,
  reserved,
  occupied,
  disabled;

  static ParkingSpotStatus fromFirestore(Object? value) => switch (value) {
    'reserved' || 'réservée' || 'reservee' => ParkingSpotStatus.reserved,
    'occupied' || 'occupée' || 'occupee' => ParkingSpotStatus.occupied,
    'disabled' || 'désactivée' || 'desactivee' => ParkingSpotStatus.disabled,
    _ => ParkingSpotStatus.available,
  };

  String get firestoreValue => switch (this) {
    ParkingSpotStatus.available => 'available',
    ParkingSpotStatus.reserved => 'reserved',
    ParkingSpotStatus.occupied => 'occupied',
    ParkingSpotStatus.disabled => 'disabled',
  };

  String get label => switch (this) {
    ParkingSpotStatus.available => 'Disponible',
    ParkingSpotStatus.reserved => 'Réservée',
    ParkingSpotStatus.occupied => 'Occupée',
    ParkingSpotStatus.disabled => 'Désactivée',
  };
}

class ParkingSpot {
  const ParkingSpot({
    required this.id,
    required this.parkingId,
    required this.code,
    required this.status,
    this.reservationId,
    this.reservedBy,
  });

  final String id;
  final String parkingId;
  final String code;
  final ParkingSpotStatus status;
  final String? reservationId;
  final String? reservedBy;

  bool get isAvailable => status == ParkingSpotStatus.available;

  Map<String, dynamic> toJson() => {
    'id': id,
    'parkingId': parkingId,
    'code': code,
    'status': status.firestoreValue,
  };
}

/// Exception affichable lorsqu'une place vient d'etre prise.
class SpotUnavailableException implements Exception {
  const SpotUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ReservationCreation {
  const ReservationCreation({
    required this.reservationId,
    required this.reservationCode,
  });

  final String reservationId;
  final String reservationCode;
}

class ParkingReservation {
  const ParkingReservation({
    required this.id,
    required this.userId,
    required this.parkingId,
    required this.parkingName,
    required this.placeCode,
    required this.dateLabel,
    required this.arrivalHour,
    required this.departureHour,
    required this.duration,
    required this.amountFC,
    required this.status,
    required this.paymentStatus,
    required this.reservationCode,
    required this.createdAt,
    this.driverName,
    this.driverEmail,
  });

  final String id;
  final String userId;
  final String parkingId;
  final String parkingName;
  final String placeCode;
  final String dateLabel;
  final int arrivalHour;
  final int departureHour;
  final int duration;
  final int amountFC;
  final String status;
  final String paymentStatus;
  final String reservationCode;
  final DateTime createdAt;
  final String? driverName;
  final String? driverEmail;

  bool get canCheckIn => status == 'confirmed' && paymentStatus == 'paid';
  bool get canCheckOut => status == 'occupied';

  String get statusLabel => switch (status) {
    'pending_payment' => 'En attente de paiement',
    'confirmed' => 'Payée \u2022 entrée attendue',
    'occupied' => 'Véhicule dans le parking',
    'completed' => 'Terminée',
    'cancelled' => 'Annulée',
    _ => status,
  };
}

/// Acces centralise pour les places et les reservations via API MongoDB.
class ParkingRepository {
  ParkingRepository._();

  static const birereParkingId = 'birere-rutshuru';
  static const birereParkingName = 'Parking Birere';

  static Stream<List<ParkingSpot>> watchSpots(String parkingId) {
    return ApiClient.pollStream(
      () => ApiClient.fetchSpots(parkingId),
      interval: const Duration(seconds: 3),
    );
  }

  static Stream<List<ParkingReservation>> watchParkingReservations(
    String parkingId,
  ) {
    return ApiClient.pollStream(() async {
      final reservations = await ApiClient.fetchReservations(
        parkingId: parkingId,
      );
      reservations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return reservations;
    }, interval: const Duration(seconds: 5));
  }

  static Future<void> ensureBirereSpots() => ensureSpots(birereParkingId);

  static Future<void> ensureSpots(String parkingId) async {
    // Crée uniquement les places manquantes.
    //
    // On ne remet surtout pas toutes les places à « disponible » : cette
    // réinitialisation effaçait l'état des réservations actives à chaque
    // ouverture du tableau de bord et le gestionnaire voyait ses
    // paiements et ses accès disparaître.
    final spots = await ApiClient.fetchSpots(parkingId);
    final existingCodes = spots.map((s) => s.code).toSet();
    const allCodes = [
      'A1',
      'A2',
      'A3',
      'A4',
      'A5',
      'B1',
      'B2',
      'B3',
      'B4',
      'B5',
      'C1',
      'C2',
      'C3',
      'C4',
      'C5',
    ];
    for (final code in allCodes) {
      if (!existingCodes.contains(code)) {
        await ApiClient.saveSpot(
          parkingId: parkingId,
          code: code,
          status: ParkingSpotStatus.available,
        );
      }
    }
  }

  static Future<ReservationCreation> createReservation({
    required User user,
    required String parkingId,
    required String parkingName,
    required String placeCode,
    required DateTime date,
    required int arrivalHour,
    required int departureHour,
  }) async {
    final duration = departureHour > arrivalHour
        ? departureHour - arrivalHour
        : 1;
    final result = await ApiClient.createReservation(
      userId: user.uid,
      parkingId: parkingId,
      parkingName: parkingName,
      placeCode: placeCode,
      date: AppUnits.frenchDate(date),
      arrivalHour: arrivalHour,
      departureHour: departureHour,
      amountFC: AppUnits.totalFor(duration),
      driverName: user.displayName?.trim().isNotEmpty == true
          ? user.displayName!.trim()
          : 'Conducteur',
      driverEmail: user.email ?? '',
    );
    if (result == null) {
      throw const SpotUnavailableException(
        'La réservation a échoué. Réessayez.',
      );
    }
    return ReservationCreation(
      reservationId: result.id,
      reservationCode: result.reservationCode,
    );
  }

  static Future<void> extendReservation({
    required String reservationId,
    required String userId,
    required int extraHours,
  }) async {
    if (extraHours <= 0) {
      throw const SpotUnavailableException(
        'La prolongation doit ajouter au moins une heure.',
      );
    }
    await ApiClient.extendReservation(reservationId, extraHours: extraHours);
  }

  static Future<void> confirmParkingPayment(String reservationId) async {
    final managerId = FirebaseAuth.instance.currentUser?.uid;
    if (managerId == null) {
      throw const SpotUnavailableException(
        'Connectez-vous comme gestionnaire pour confirmer un paiement.',
      );
    }
    await ApiClient.confirmPayment(reservationId);
  }

  /// Déplace une réservation sur une autre place encore disponible.
  ///
  /// Relevé de place après un conflit détecté au moment du paiement : on
  /// renvoie [SpotUnavailableException] si cette nouvelle place est déjà
  /// engagée, afin que le conducteur en choisisse une autre.
  static Future<void> changeReservationPlace(
    String reservationId,
    String placeCode,
  ) => ApiClient.changeReservationPlace(reservationId, placeCode);

  static Future<void> checkInReservation(String reservationId) async {
    final managerId = FirebaseAuth.instance.currentUser?.uid;
    if (managerId == null) {
      throw const SpotUnavailableException(
        'Connectez-vous comme gestionnaire.',
      );
    }
    await ApiClient.checkInReservation(reservationId);
  }

  static Future<void> checkOutReservation(String reservationId) async {
    final managerId = FirebaseAuth.instance.currentUser?.uid;
    if (managerId == null) {
      throw const SpotUnavailableException(
        'Connectez-vous comme gestionnaire.',
      );
    }
    await ApiClient.checkOutReservation(reservationId);
  }

  static Future<void> cancelReservation({
    required String reservationId,
    required String userId,
  }) async {
    await ApiClient.cancelReservation(reservationId);
  }

  static Future<void> saveSpot({
    required String parkingId,
    required String code,
    required ParkingSpotStatus status,
  }) async {
    final normalizedCode = code.trim().toUpperCase();
    if (normalizedCode.isEmpty) {
      throw const SpotUnavailableException(
        'Le code de la place est obligatoire.',
      );
    }
    await ApiClient.saveSpot(
      parkingId: parkingId,
      code: normalizedCode,
      status: status,
    );
  }
}
