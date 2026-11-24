/// When Android Auto last talked to the app: the car asking for its menus
/// (getChildren), getting ready to play (prepare), a tap in the car. Android
/// gives the app no plain "car connected" signal, and Wi-Fi can't stand in
/// for it: with wireless Android Auto the phone's Wi-Fi is joined to the head
/// unit, which has no internet (Nov 16, 2026), so "on Wi-Fi" reads true in
/// the truck while everything really goes over cellular. Recent car traffic
/// is the proxy. Used to keep a background update download off the car's
/// connection.
class CarActivity {
  CarActivity._();

  static DateTime? _last;

  static void touch() => _last = DateTime.now();

  /// The car talked to the app in the last 10 minutes.
  static bool get recent =>
      _last != null &&
      DateTime.now().difference(_last!) < const Duration(minutes: 10);
}
