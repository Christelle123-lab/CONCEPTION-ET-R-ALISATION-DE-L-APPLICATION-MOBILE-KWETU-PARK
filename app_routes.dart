import 'auth_service.dart';

/// Chemins uniques de navigation de Kwetu Park.
///
/// Centraliser ces chemins évite qu'un gestionnaire soit redirigé par erreur
/// vers un écran conducteur après une connexion Firebase réussie.
abstract final class AppRoutes {
  static const home = '/';
  static const userDashboard = '/dashboard/user';
  static const managerDashboard = '/dashboard/manager';
  static const adminDashboard = '/dashboard/admin';

  static String dashboardFor(AppUserRole role) => switch (role) {
    AppUserRole.manager => managerDashboard,
    AppUserRole.administrator => adminDashboard,
    AppUserRole.driver || AppUserRole.unknown => userDashboard,
  };
}
