import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'services/api_client.dart';

/// Temps maximal accordé à une lecture Firestore de rôle.
///
/// Sur un réseau instable le SDK attend indéfiniment : le tableau de bord
/// restait alors bloqué sur le spinner de chargement du garde de rôle.
const Duration _roleReadTimeout = Duration(seconds: 4);

/// Délai dur global d'une résolution de rôle.
///
/// L'API serveur échoue en 8 s, chaque lecture Firestore peut en coûter 8 de
/// plus : sans plafond, un compte dont le téléphone n'atteint pas le serveur
/// affichait indéfiniment le spinner du garde de rôle. Passé ce délai on
/// abandonne et le garde propose « Réessayer ».
const Duration _roleResolveDeadline = Duration(seconds: 12);

/// Roles canoniques utilises dans Firestore.
///
/// Les documents dedies `managers/{uid}` et `administrators/{uid}` sont la
/// source prioritaire des privileges. Par compatibilite avec les comptes du
/// personnel deja enregistres dans Firebase Console, un role de personnel
/// present dans `users/{uid}` est aussi accepte ; les regles Firestore
/// empechent un conducteur de se donner lui-meme ce role.
enum AppUserRole {
  driver,
  manager,
  administrator,
  unknown;

  String get value => switch (this) {
    AppUserRole.driver => 'driver',
    AppUserRole.manager => 'manager',
    AppUserRole.administrator => 'administrator',
    AppUserRole.unknown => 'unknown',
  };

  bool get canManageParking =>
      this == AppUserRole.manager || this == AppUserRole.administrator;
}

/// Resultat de la verification du role d'un compte connecte.
class UserRoleProfile {
  const UserRoleProfile({
    required this.uid,
    required this.role,
    required this.email,
    this.data = const {},
  });

  final String uid;
  final AppUserRole role;
  final String email;
  final Map<String, dynamic> data;

  bool get canManageParking => role.canManageParking;
}

/// Levee lorsqu'un compte Firebase est valide mais ne possede pas le role
/// necessaire pour acceder a un espace protege.
class RoleAccessException implements Exception {
  const RoleAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Point d'acces unique aux comptes Kwetu Park.
/// Les profils crees ici sont stockes dans Firestore avec le role conducteur.
class AuthService {
  AuthService._();

  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Flux d'authentification unique partagé par tous les écrans.
  ///
  /// Mémorisé : le recréer à chaque rebuild (get) désabonnait les
  /// StreamBuilder et provoquait un écran de chargement qui clignotait.
  static final Stream<User?> authStateChanges = _auth.authStateChanges();
  static User? get currentUser => _auth.currentUser;

  /// Dernier rôle résolu par compte, conservé pendant la session.
  ///
  /// Si le serveur se tait (connexion perdue) et que Firestore n'a rien à
  /// dire, un gestionnaire reste gestionnaire au lieu d'être dégradé en
  /// conducteur — ce qui l'aurait renvoyé sur « Accès non autorisé ».
  static final Map<String, AppUserRole> _roleCache = {};

  /// Retourne le role effectivement accorde au compte.
  ///
  /// Methode hybride : API MongoDB en priorite, fallback Firestore.
  static Future<UserRoleProfile> getUserRoleProfile([String? uid]) async {
    final profile = await _resolveUserRoleProfile(uid).timeout(
      _roleResolveDeadline,
      onTimeout: () {
        final accountId = uid ?? _auth.currentUser?.uid;
        final cachedRole = accountId == null ? null : _roleCache[accountId];
        if (cachedRole != null) {
          return UserRoleProfile(
            uid: accountId!,
            role: cachedRole,
            email: _auth.currentUser?.email ?? '',
          );
        }
        throw const RoleAccessException(
          'La vérification du rôle a pris trop de temps. Vérifiez que le '
          'téléphone est connecté au même Wi-Fi que le serveur.',
        );
      },
    );
    _roleCache[profile.uid] = profile.role;
    return profile;
  }

  static Future<UserRoleProfile> _resolveUserRoleProfile([String? uid]) async {
    final accountId = uid ?? _auth.currentUser?.uid;
    if (accountId == null) {
      throw const RoleAccessException('Aucun utilisateur n\'est connecte.');
    }
    final userEmail = _auth.currentUser?.email ?? '';

    // 1) Essai via le serveur MongoDB (API REST).
    try {
      final data = await ApiClient.fetchUserRole(accountId, email: userEmail);
      final roleStr = data['role'] as String? ?? 'driver';
      final role = _roleFromValue(roleStr);
      if (role != AppUserRole.unknown) {
        return UserRoleProfile(
          uid: accountId,
          role: role,
          email: userEmail,
          data: data,
        );
      }
    } catch (_) {}

    // 2) Fallback Firestore (si le serveur MongoDB n'est pas joignable).
    //    Les lectures sont parallélisées : en séquence elles cumulaient
    //    plusieurs fois leur propre délai et figeaient longuement le garde.
    final roleDocuments = await Future.wait([
      _readRoleDocument('users', accountId),
      _readRoleDocument('managers', accountId),
      _readRoleDocument('administrators', accountId),
      _readRoleDocument('administrateur', accountId),
    ]);
    final userDocument = roleDocuments[0];
    var managerDocument = roleDocuments[1];
    var administratorDocument = roleDocuments[2];
    var legacyStaffDocument = roleDocuments[3];
    final email = userEmail.isNotEmpty
        ? userEmail
        : (userDocument?.data()?['email'] as String? ?? '');

    if (email.isNotEmpty) {
      final lookups =
          await Future.wait<DocumentSnapshot<Map<String, dynamic>>?>([
            managerDocument == null
                ? _findRoleDocumentByEmail('managers', email)
                : Future.value(null),
            administratorDocument == null
                ? _findRoleDocumentByEmail('administrators', email)
                : Future.value(null),
            legacyStaffDocument == null
                ? _findRoleDocumentByEmail('administrateur', email)
                : Future.value(null),
          ]);
      managerDocument ??= lookups[0];
      administratorDocument ??= lookups[1];
      legacyStaffDocument ??= lookups[2];
    }
    var legacyByEmail = legacyStaffDocument;

    if (_isActiveRoleDocument(
      administratorDocument?.data(),
      AppUserRole.administrator,
    )) {
      return UserRoleProfile(
        uid: accountId,
        role: AppUserRole.administrator,
        email: email,
        data: administratorDocument!.data() ?? const {},
      );
    }
    if (_isActiveRoleDocument(managerDocument?.data(), AppUserRole.manager)) {
      return UserRoleProfile(
        uid: accountId,
        role: AppUserRole.manager,
        email: email,
        data: managerDocument!.data() ?? const {},
      );
    }
    final legacyData = legacyByEmail?.data();
    final legacyRole = _roleFromValue(legacyData?['role']);
    if (_isActiveLegacyStaffDocument(legacyData) &&
        legacyRole.canManageParking) {
      return UserRoleProfile(
        uid: accountId,
        role: legacyRole,
        email: email,
        data: legacyData ?? const {},
      );
    }
    final commonData = userDocument?.data() ?? const <String, dynamic>{};

    // 3) Ni le serveur ni Firestore n'ont confirmé le rôle : on revient au
    //    dernier rôle connu du compte plutôt qu'au moindre privilège.
    final cachedRole = _roleCache[accountId];
    if (cachedRole != null && cachedRole.canManageParking) {
      return UserRoleProfile(
        uid: accountId,
        role: cachedRole,
        email: email,
        data: commonData,
      );
    }

    final commonRole = _roleFromValue(commonData['role']);
    if (commonRole != AppUserRole.unknown) {
      return UserRoleProfile(
        uid: accountId,
        role: commonRole,
        email: email,
        data: commonData,
      );
    }
    return UserRoleProfile(
      uid: accountId,
      role: AppUserRole.driver,
      email: email,
      data: commonData,
    );
  }

  /// Lit `{collection}/{accountId}` en priorisant le serveur, puis le cache
  /// local si le serveur est injoignable. Retourne `null` si la lecture est
  /// impossible, l'appelant en deduit alors le role de moindre privilege.
  static Future<DocumentSnapshot<Map<String, dynamic>>?> _readRoleDocument(
    String collection,
    String accountId,
  ) async {
    final reference = _db.collection(collection).doc(accountId);
    try {
      return await reference
          .get(const GetOptions(source: Source.server))
          .timeout(_roleReadTimeout);
    } catch (_) {
      // Serveur Firestore muet, inaccessible ou trop lent : cache local.
      try {
        return await reference.get().timeout(_roleReadTimeout);
      } catch (_) {
        return null;
      }
    }
  }

  /// Recherche un document de role par e-mail dans la collection donnee.
  /// Utilise en secours lorsque le document n'a pas ete trouve par UID.
  static Future<DocumentSnapshot<Map<String, dynamic>>?>
  _findRoleDocumentByEmail(String collection, String email) async {
    try {
      final snapshot = await _db
          .collection(collection)
          .where('email', isEqualTo: email)
          .limit(1)
          .get(const GetOptions(source: Source.server))
          .timeout(_roleReadTimeout);
      if (snapshot.docs.isNotEmpty) return snapshot.docs.first;
      return null;
    } catch (_) {
      try {
        final snapshot = await _db
            .collection(collection)
            .where('email', isEqualTo: email)
            .limit(1)
            .get()
            .timeout(_roleReadTimeout);
        if (snapshot.docs.isNotEmpty) return snapshot.docs.first;
      } catch (_) {
        // Ignore : le role de moindre privilege sera utilise.
      }
      return null;
    }
  }

  static Future<AppUserRole> getCurrentUserRole() async =>
      (await getUserRoleProfile()).role;

  static Future<bool> currentUserCanManageParking() async =>
      (await getUserRoleProfile()).canManageParking;

  static Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await _resolveAndRecordLogin(credential.user!);
    return credential;
  }

  static Future<UserRoleProfile> signInAndResolveRole({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return _resolveAndRecordLogin(credential.user!);
  }

  static Future<UserCredential> signUp({
    required String name,
    required String phone,
    required String plate,
    required String email,
    required String password,
  }) async {
    final result = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await result.user!.updateDisplayName(name.trim());
    await _saveDriverProfile(
      result.user!,
      name: name,
      phone: phone,
      plate: plate,
      updateDetails: true,
    );
    return result;
  }

  static Future<UserRoleProfile> signInAsManagerOrAdministrator({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    try {
      final profile = await _resolveAndRecordLogin(credential.user!);
      if (!profile.canManageParking) {
        await _auth.signOut();
        throw const RoleAccessException(
          'Ce compte n\'est pas autorise a acceder a l\'espace gestionnaire.',
        );
      }
      return profile;
    } on RoleAccessException {
      if (_auth.currentUser?.uid == credential.user?.uid) {
        await _auth.signOut();
      }
      rethrow;
    } catch (_) {
      // Ne pas bloquer la connexion si l'écriture Firestore échoue.
      final profile = await getUserRoleProfile(credential.user!.uid);
      if (!profile.canManageParking) {
        if (_auth.currentUser?.uid == credential.user?.uid) {
          await _auth.signOut();
        }
        throw const RoleAccessException(
          'Ce compte n\'est pas autorise a acceder a l\'espace gestionnaire.',
        );
      }
      return profile;
    }
  }

  static Future<void> resetPassword(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  static Future<void> signOut() => _auth.signOut();

  static Future<UserRoleProfile> _resolveAndRecordLogin(User user) async {
    final profile = await getUserRoleProfile(user.uid);
    // Enregistrer la connexion via l'API (ne jamais bloquer).
    try {
      await ApiClient.updateUserProfile(uid: user.uid, name: user.displayName);
    } catch (_) {}
    if (profile.role == AppUserRole.unknown) {
      return UserRoleProfile(
        uid: profile.uid,
        role: AppUserRole.driver,
        email: profile.email,
        data: profile.data,
      );
    }
    return profile;
  }

  static Future<void> _saveDriverProfile(
    User user, {
    required String name,
    required String phone,
    required String plate,
    bool updateDetails = false,
  }) async {
    try {
      await ApiClient.updateUserProfile(
        uid: user.uid,
        name: name,
        phone: phone,
        vehiclePlate: plate,
      );
    } catch (_) {}
  }

  static bool _isActiveRoleDocument(
    Map<String, dynamic>? data,
    AppUserRole expectedRole,
  ) {
    if (data == null) return false;
    if (data['active'] == false || data['disabled'] == true) return false;

    final declaredRole = _roleFromValue(data['role']);
    return declaredRole == AppUserRole.unknown || declaredRole == expectedRole;
  }

  static bool _isActiveLegacyStaffDocument(Map<String, dynamic>? data) {
    if (data == null) return false;
    return data['active'] != false && data['disabled'] != true;
  }

  static AppUserRole _roleFromValue(Object? value) {
    switch ((value as String? ?? '').trim().toLowerCase()) {
      case 'driver':
      case 'conducteur':
        return AppUserRole.driver;
      case 'manager':
      case 'gestionnaire':
        return AppUserRole.manager;
      case 'administrator':
      case 'administrateur':
      case 'admin':
        return AppUserRole.administrator;
      default:
        return AppUserRole.unknown;
    }
  }
}
