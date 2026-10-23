import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:intl/intl.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } on FirebaseException catch (error) {
    debugPrint('Firebase is not configured; starting in demo mode: $error');
  } on AssertionError catch (error) {
    debugPrint('Firebase is not configured; starting in demo mode: $error');
  }
  runApp(const SmartTownshipApp());
}

// ============================================================================
// 1. FIRESTORE-BACKED APPLICATION STATE
// ============================================================================
class GuestInvite {
  final String id;
  final String guestName;
  final String plateNumber;
  final DateTime startTime;
  final DateTime endTime;
  final String status; // 'PENDING', 'APPROVED', 'REJECTED'

  GuestInvite({
    required this.id,
    required this.guestName,
    required this.plateNumber,
    required this.startTime,
    required this.endTime,
    required this.status,
  });
}

class GateScanLog {
  final String plateOrQr;
  final String role;
  final String unit;
  final bool granted;
  final String message;
  final DateTime timestamp;

  GateScanLog({
    required this.plateOrQr,
    required this.role,
    required this.unit,
    required this.granted,
    required this.message,
    required this.timestamp,
  });
}

class AppState extends ChangeNotifier {
  static const String unitDocumentId = 'UNIT_A_10_02';

  final FirebaseFirestore? firestore = _tryGetFirestore();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _unitsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _invitationsSubscription;

  String unitNumber = '';
  String residentName = '';
  String residentPlate = '';
  bool isMaintenancePaid = false;
  double overdueAmount = 0;
  List<GuestInvite> invites = [];

  // Live Guardhouse Logs
  List<GateScanLog> scanLogs = [];

  AppState() {
    if (firestore == null) {
      unitNumber = unitDocumentId;
      residentName = 'Demo Resident';
      residentPlate = 'DEMO123';
      overdueAmount = 120;
      invites = [
        GuestInvite(
          id: 'demo-invite',
          guestName: 'Demo Visitor',
          plateNumber: 'VISITOR1',
          startTime: DateTime.now().subtract(const Duration(minutes: 15)),
          endTime: DateTime.now().add(const Duration(hours: 3)),
          status: 'APPROVED',
        ),
      ];
    } else {
      _listenToUnit();
      _listenToInvitations();
    }
  }

  static FirebaseFirestore? _tryGetFirestore() {
    try {
      return FirebaseFirestore.instance;
    } on FirebaseException catch (error) {
      debugPrint('Firestore is unavailable; using demo mode: $error');
      return null;
    } on AssertionError catch (error) {
      debugPrint('Firestore is unavailable; using demo mode: $error');
      return null;
    }
  }

  void _listenToUnit() {
    _unitsSubscription = firestore!
        .collection('units')
        .snapshots()
        .listen(
          (snapshot) {
            QueryDocumentSnapshot<Map<String, dynamic>>? unitDocument;
            for (final document in snapshot.docs) {
              if (document.id == unitDocumentId) {
                unitDocument = document;
                break;
              }
            }
            if (unitDocument == null) {
              unitNumber = '';
              residentName = '';
              residentPlate = '';
              isMaintenancePaid = false;
              overdueAmount = 0;
            } else {
              final data = unitDocument.data();
              unitNumber = unitDocument.id;
              residentName = data['owner_name'] as String? ?? '';
              residentPlate = data['resident_plate'] as String? ?? '';
              isMaintenancePaid = data['maintenance_status'] == 'PAID';
              overdueAmount = (data['overdue_amount'] as num?)?.toDouble() ?? 0;
            }
            notifyListeners();
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Failed to listen to units: $error');
          },
        );
  }

  void _listenToInvitations() {
    _invitationsSubscription = firestore!
        .collection('invitations')
        .where('host_unit', isEqualTo: unitDocumentId)
        .snapshots()
        .listen(
          (snapshot) {
            invites = snapshot.docs.map((document) {
              final data = document.data();
              return GuestInvite(
                id: document.id,
                guestName: data['guest_name'] as String? ?? '',
                plateNumber: data['guest_plate'] as String? ?? '',
                startTime: _asDateTime(data['valid_start']),
                endTime: _asDateTime(data['valid_end']),
                status: data['status'] as String? ?? 'PENDING',
              );
            }).toList()..sort((a, b) => b.startTime.compareTo(a.startTime));
            notifyListeners();
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Failed to listen to invitations: $error');
          },
        );
  }

  static DateTime _asDateTime(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Actions
  Future<void> payMaintenanceFee() async {
    if (firestore == null) {
      isMaintenancePaid = true;
      overdueAmount = 0;
      notifyListeners();
      return;
    }
    await firestore!.collection('units').doc(unitDocumentId).update({
      'maintenance_status': 'PAID',
    });
  }

  Future<void> updateInviteStatus(String id, String newStatus) async {
    if (firestore == null) {
      final index = invites.indexWhere((invite) => invite.id == id);
      if (index != -1) {
        final invite = invites[index];
        invites[index] = GuestInvite(
          id: invite.id,
          guestName: invite.guestName,
          plateNumber: invite.plateNumber,
          startTime: invite.startTime,
          endTime: invite.endTime,
          status: newStatus,
        );
        notifyListeners();
      }
      return;
    }
    await firestore!.collection('invitations').doc(id).update({
      'status': newStatus,
    });
  }

  Future<void> updateGuestPlate(String id, String newPlate) async {
    final cleanedPlate = newPlate.toUpperCase().replaceAll(' ', '');
    if (firestore == null) {
      final index = invites.indexWhere((invite) => invite.id == id);
      if (index != -1) {
        final invite = invites[index];
        invites[index] = GuestInvite(
          id: invite.id,
          guestName: invite.guestName,
          plateNumber: cleanedPlate,
          startTime: invite.startTime,
          endTime: invite.endTime,
          status: invite.status,
        );
        notifyListeners();
      }
      return;
    }
    await firestore!.collection('invitations').doc(id).update({
      'guest_plate': cleanedPlate,
    });
  }

  Future<void> createGuestInvite(
    String name,
    String plate,
    DateTime start,
    DateTime end,
  ) async {
    final cleanedPlate = plate.toUpperCase().replaceAll(' ', '');
    if (firestore == null) {
      invites.add(
        GuestInvite(
          id: 'demo-${DateTime.now().microsecondsSinceEpoch}',
          guestName: name,
          plateNumber: cleanedPlate,
          startTime: start,
          endTime: end,
          status: 'PENDING',
        ),
      );
      notifyListeners();
      return;
    }
    await firestore!.collection('invitations').add({
      'host_unit': unitDocumentId,
      'guest_name': name,
      'guest_plate': cleanedPlate,
      'valid_start': Timestamp.fromDate(start),
      'valid_end': Timestamp.fromDate(end),
      'status': 'PENDING',
      'pass_type': plate == 'QR-ONLY' ? 'DYNAMIC_QR' : 'ANPR_ONLY',
    });
  }

  @override
  void dispose() {
    _unitsSubscription?.cancel();
    _invitationsSubscription?.cancel();
    super.dispose();
  }

  void simulateGateScan(String inputPlateOrQr, {bool isQr = false}) {
    final cleaned = inputPlateOrQr.toUpperCase().replaceAll(' ', '');
    final now = DateTime.now();

    // Case 1: Resident Plate Scanned
    if (cleaned == residentPlate) {
      if (isMaintenancePaid) {
        scanLogs.insert(
          0,
          GateScanLog(
            plateOrQr: cleaned,
            role: "RESIDENT",
            unit: unitNumber,
            granted: true,
            message: "Fast-Track ANPR Approved. Boom Gate Opened.",
            timestamp: now,
          ),
        );
      } else {
        scanLogs.insert(
          0,
          GateScanLog(
            plateOrQr: cleaned,
            role: "RESIDENT",
            unit: unitNumber,
            granted: false,
            message:
                "RESTRICTED: RM ${overdueAmount.toStringAsFixed(2)} Maintenance Fee Overdue. Redirected to manual lane & sent payment prompt.",
            timestamp: now,
          ),
        );
      }
      notifyListeners();
      return;
    }

    // Case 2: Guest Plate or Dynamic QR Scanned
    GuestInvite? matchedInvite;
    for (var inv in invites) {
      if (inv.plateNumber == cleaned || cleaned.startsWith(inv.id)) {
        matchedInvite = inv;
        break;
      }
    }

    if (matchedInvite == null) {
      scanLogs.insert(
        0,
        GateScanLog(
          plateOrQr: cleaned,
          role: "UNKNOWN",
          unit: "N/A",
          granted: false,
          message: "DENIED: Unregistered vehicle plate / Invalid QR.",
          timestamp: now,
        ),
      );
    } else if (matchedInvite.status != "APPROVED") {
      scanLogs.insert(
        0,
        GateScanLog(
          plateOrQr: cleaned,
          role: "VISITOR (${matchedInvite.guestName})",
          unit: unitNumber,
          granted: false,
          message: "DENIED: Host has not approved this request yet.",
          timestamp: now,
        ),
      );
    } else if (!isMaintenancePaid) {
      scanLogs.insert(
        0,
        GateScanLog(
          plateOrQr: cleaned,
          role: "VISITOR (${matchedInvite.guestName})",
          unit: unitNumber,
          granted: false,
          message:
              "RESTRICTED: Host Unit ($unitNumber) has overdue maintenance fees. Fast-track guest pass disabled.",
          timestamp: now,
        ),
      );
    } else if (now.isBefore(
          matchedInvite.startTime.subtract(const Duration(minutes: 30)),
        ) ||
        now.isAfter(matchedInvite.endTime)) {
      scanLogs.insert(
        0,
        GateScanLog(
          plateOrQr: cleaned,
          role: "VISITOR (${matchedInvite.guestName})",
          unit: unitNumber,
          granted: false,
          message: "DENIED: Outside pre-booked time window.",
          timestamp: now,
        ),
      );
    } else {
      scanLogs.insert(
        0,
        GateScanLog(
          plateOrQr: isQr ? "QR: ${matchedInvite.id}" : cleaned,
          role: "VISITOR (${matchedInvite.guestName})",
          unit: unitNumber,
          granted: true,
          message: isQr
              ? "Dynamic QR Verified! Boom Gate Opened (Assigned Bay: V-14)."
              : "Guest ANPR Verified! Boom Gate Opened (Assigned Bay: V-14).",
          timestamp: now,
        ),
      );
    }
    notifyListeners();
  }
}

final AppState globalAppState = AppState();

// ============================================================================
// 2. MAIN APP SHELL & ROLE SWITCHER
// ============================================================================
class SmartTownshipApp extends StatelessWidget {
  const SmartTownshipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SDP Smart Gate Ecosystem',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFB71C1C), // Sime Darby Red accent
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      ),
      home: const MainRoleSwitcherScreen(),
    );
  }
}

class MainRoleSwitcherScreen extends StatefulWidget {
  const MainRoleSwitcherScreen({super.key});

  @override
  State<MainRoleSwitcherScreen> createState() => _MainRoleSwitcherScreenState();
}

class _MainRoleSwitcherScreenState extends State<MainRoleSwitcherScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: globalAppState,
      builder: (context, _) {
        final screens = [
          ResidentScreen(appState: globalAppState),
          GuestPassScreen(appState: globalAppState),
          GuardDashboardScreen(appState: globalAppState),
        ];

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF8E1515),
            foregroundColor: Colors.white,
            title: const Row(
              children: [
                Icon(Icons.shield_outlined),
                SizedBox(width: 10),
                Text(
                  "SDP Township Smart Gate",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: null,
                icon: Icon(
                  globalAppState.isMaintenancePaid
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  color: globalAppState.isMaintenancePaid
                      ? Colors.greenAccent
                      : Colors.amberAccent,
                ),
                label: Text(
                  globalAppState.isMaintenancePaid
                      ? "Fee: PAID"
                      : "Fee: OVERDUE",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: screens[_selectedIndex],
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (idx) =>
                setState(() => _selectedIndex = idx),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: '1. Resident App',
              ),
              NavigationDestination(
                icon: Icon(Icons.qr_code_2_outlined),
                selectedIcon: Icon(Icons.qr_code_2),
                label: '2. Guest Web Pass',
              ),
              NavigationDestination(
                icon: Icon(Icons.videocam_outlined),
                selectedIcon: Icon(Icons.videocam),
                label: '3. Guardhouse ANPR',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================================
// VIEW 1: RESIDENT PORTAL (Fee Settlement + Guest Approval)
// ============================================================================
class ResidentScreen extends StatelessWidget {
  final AppState appState;
  const ResidentScreen({super.key, required this.appState});

  void _showNewInviteModal(BuildContext context) {
    final nameCtrl = TextEditingController();
    final plateCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Pre-Register Visitor"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: "Visitor / Delivery Name",
                hintText: "e.g., GrabFood / Uncle Wong",
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: plateCtrl,
              decoration: const InputDecoration(
                labelText: "Car Plate Number (Optional for QR)",
                hintText: "e.g., VAB 5678",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty) {
                appState
                    .createGuestInvite(
                      nameCtrl.text,
                      plateCtrl.text.isEmpty ? "QR-ONLY" : plateCtrl.text,
                      DateTime.now(),
                      DateTime.now().add(const Duration(hours: 3)),
                    )
                    .then((_) {
                      if (ctx.mounted) Navigator.pop(ctx);
                    })
                    .catchError((Object error) {
                      debugPrint('Failed to create guest invite: $error');
                    });
              }
            },
            child: const Text("Generate Pass"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timeFormat = DateFormat('h:mm a');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Resident Profile Header
        Card(
          elevation: 0,
          color: Colors.white,
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFF8E1515),
              foregroundColor: Colors.white,
              child: Icon(Icons.person),
            ),
            title: Text(
              appState.residentName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              "Unit: ${appState.unitNumber} • Plate: ${appState.residentPlate}",
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Maintenance Fee Status Banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: appState.isMaintenancePaid
                ? Colors.green.shade50
                : Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: appState.isMaintenancePaid
                  ? Colors.green.shade300
                  : Colors.red.shade300,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    appState.isMaintenancePaid
                        ? Icons.verified_rounded
                        : Icons.lock_clock_rounded,
                    color: appState.isMaintenancePaid
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      appState.isMaintenancePaid
                          ? "Fast-Track Gate Access: ACTIVE"
                          : "Fast-Track Gate Access: PAUSED (Maintenance Overdue)",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: appState.isMaintenancePaid
                            ? Colors.green.shade900
                            : Colors.red.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                appState.isMaintenancePaid
                    ? "Your maintenance account is in good standing. Resident ANPR & Visitor Fast-Track invites are enabled."
                    : "You have an overdue maintenance balance of RM ${appState.overdueAmount.toStringAsFixed(2)}. Automated boom gate entry & visitor fast-track passes are restricted until settled.",
              ),
              if (!appState.isMaintenancePaid) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                    ),
                    onPressed: () {
                      appState
                          .payMaintenanceFee()
                          .then((_) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  "Payment Successful via DuitNow! Fast-Track ANPR Gate Unlocked.",
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                          })
                          .catchError((Object error) {
                            debugPrint('Failed to pay maintenance fee: $error');
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  "Payment failed. Please try again.",
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          });
                    },
                    icon: const Icon(Icons.bolt),
                    label: const Text(
                      "1-Tap Instant Settlement (RM 150.00 via DuitNow)",
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Visitor Invitations Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Visitor & Delivery Passes",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _showNewInviteModal(context),
              icon: const Icon(Icons.add),
              label: const Text("New Invite"),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Visitor Invitations List
        ...appState.invites.map((inv) {
          final isPending = inv.status == "PENDING";
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        inv.guestName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Chip(
                        label: Text(
                          inv.status,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        backgroundColor: inv.status == "APPROVED"
                            ? Colors.green.shade100
                            : Colors.amber.shade100,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Plate: ${inv.plateNumber} • Pass ID: ${inv.id}",
                    style: const TextStyle(color: Colors.black54),
                  ),
                  Text(
                    "Window: ${timeFormat.format(inv.startTime)} – ${timeFormat.format(inv.endTime)}",
                    style: const TextStyle(color: Colors.black54),
                  ),
                  if (isPending) ...[
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () =>
                              appState.updateInviteStatus(inv.id, "REJECTED"),
                          child: const Text("Decline"),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () =>
                              appState.updateInviteStatus(inv.id, "APPROVED"),
                          child: const Text("Approve Entry Window"),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ============================================================================
// VIEW 2: GUEST WEB PASS (Time-Bound Dynamic QR + Last-Minute Plate Swap)
// ============================================================================
class GuestPassScreen extends StatefulWidget {
  final AppState appState;
  const GuestPassScreen({super.key, required this.appState});

  @override
  State<GuestPassScreen> createState() => _GuestPassScreenState();
}

class _GuestPassScreenState extends State<GuestPassScreen> {
  int _secondsRemaining = 60;
  late Timer _timer;
  int _timeBucket = DateTime.now().millisecondsSinceEpoch ~/ 60000;
  final TextEditingController _plateSwapCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _secondsRemaining--;
        if (_secondsRemaining <= 0) {
          _secondsRemaining = 60;
          _timeBucket = DateTime.now().millisecondsSinceEpoch ~/ 60000;
        }
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _plateSwapCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.appState.invites.isEmpty) {
      return const Center(child: Text("No visitor passes are available yet."));
    }
    final activeInvite = widget.appState.invites.first;
    final dynamicQrPayload =
        "${activeInvite.id}|${activeInvite.plateNumber}|T:$_timeBucket";

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Chip(
                    avatar: Icon(Icons.public, size: 18),
                    label: Text("No-App Web Visitor Pass"),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    activeInvite.guestName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "Visiting Unit ${widget.appState.unitNumber}",
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 16),

                  // Dynamic QR Code Box
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                    ),
                    child: Column(
                      children: [
                        QrImageView(
                          data: dynamicQrPayload,
                          version: QrVersions.auto,
                          size: 200.0,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.sync,
                              size: 16,
                              color: Colors.teal,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              "Dynamic Token refreshes in $_secondsRemaining s",
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Colors.teal,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Registered Plate Display & Last-Minute Swap (For Grab/Different Car)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          "Registered Car Plate: ${activeInvite.plateNumber}",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "Taking a Grab or driving a different car? Update your plate up to 5 mins before arrival for hands-free ANPR:",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _plateSwapCtrl,
                                decoration: const InputDecoration(
                                  hintText: "New Plate (e.g. VCE9911)",
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                if (_plateSwapCtrl.text.isNotEmpty) {
                                  widget.appState.updateGuestPlate(
                                    activeInvite.id,
                                    _plateSwapCtrl.text,
                                  );
                                  _plateSwapCtrl.clear();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        "Car Plate Updated for Hands-Free ANPR!",
                                      ),
                                    ),
                                  );
                                }
                              },
                              child: const Text("Swap"),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// VIEW 3: GUARDHOUSE LIVE ANPR DASHBOARD (Raspberry Pi Simulator + Live Logs)
// ============================================================================
class GuardDashboardScreen extends StatelessWidget {
  final AppState appState;
  const GuardDashboardScreen({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    final latestScan = appState.scanLogs.isNotEmpty
        ? appState.scanLogs.first
        : null;
    final timeFormat = DateFormat('HH:mm:ss');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Simulation Bar (Simulates @maybeimawok's Raspberry Pi Camera Triggers)
          Card(
            color: const Color(0xFF1E293B),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.memory, color: Colors.cyanAccent),
                      SizedBox(width: 8),
                      Text(
                        "Raspberry Pi Edge Camera Simulator (Test Triggers)",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () =>
                            appState.simulateGateScan(appState.residentPlate),
                        icon: const Icon(Icons.directions_car),
                        label: Text(
                          "Scan Resident (${appState.residentPlate})",
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: appState.invites.isEmpty
                            ? null
                            : () => appState.simulateGateScan(
                                appState.invites.first.plateNumber,
                              ),
                        icon: const Icon(Icons.badge),
                        label: Text(
                          appState.invites.isEmpty
                              ? "Scan Guest Plate (none)"
                              : "Scan Guest Plate (${appState.invites.first.plateNumber})",
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: appState.invites.isEmpty
                            ? null
                            : () => appState.simulateGateScan(
                                appState.invites.first.id,
                                isQr: true,
                              ),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text("Scan Grab Dynamic QR"),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => appState.simulateGateScan("BGF9999"),
                        icon: const Icon(Icons.gpp_bad),
                        label: const Text("Scan Unknown Car (BGF9999)"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Live Boom Gate Decision Banner
          if (latestScan != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: latestScan.granted
                    ? Colors.green.shade700
                    : Colors.red.shade700,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    latestScan.granted
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    color: Colors.white,
                    size: 40,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${latestScan.granted ? 'BOOM GATE OPENED' : 'ENTRY RESTRICTED'} — ${latestScan.plateOrQr}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          latestScan.message,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),

          const Text(
            "Real-Time Gate Verification Log",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          // Live Scan History
          Expanded(
            child: appState.scanLogs.isEmpty
                ? const Center(
                    child: Text(
                      "No vehicles scanned yet. Click a Raspberry Pi simulation button above!",
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                : ListView.builder(
                    itemCount: appState.scanLogs.length,
                    itemBuilder: (context, index) {
                      final log = appState.scanLogs[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            log.granted ? Icons.lock_open : Icons.lock_outline,
                            color: log.granted ? Colors.green : Colors.red,
                          ),
                          title: Text(
                            "${log.plateOrQr} • ${log.role} (Unit: ${log.unit})",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(log.message),
                          trailing: Text(
                            timeFormat.format(log.timestamp),
                            style: const TextStyle(color: Colors.black54),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
