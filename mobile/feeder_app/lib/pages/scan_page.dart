// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Page de scan BLE pour trouver et se connecter au distributeur Feeder.
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'animals_page.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  String? _error;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  /// Récupère le nom BLE d'un résultat de scan.
  /// Cherche dans les données d'advertising ET dans platformName.
  String _getDeviceName(ScanResult result) {
    // Priorité 1 : nom dans les données d'advertising (le plus fiable)
    final advName = result.advertisementData.advName;
    if (advName.isNotEmpty) return advName;

    // Priorité 2 : nom de la plateforme (peut être vide sur certains Android)
    final platformName = result.device.platformName;
    if (platformName.isNotEmpty) return platformName;

    return '';
  }

  /// Vérifie si un résultat de scan est un distributeur Feeder.
  bool _isFeeder(ScanResult result) {
    final name = _getDeviceName(result).toLowerCase();
    return name.contains('feeder');
  }

  Future<void> _startScan() async {
    setState(() {
      _results = [];
      _error = null;
      _scanning = true;
    });

    try {
      // Vérifier Bluetooth activé
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        setState(() {
          _error = 'Veuillez activer le Bluetooth';
          _scanning = false;
        });
        return;
      }

      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        if (!mounted) return;

        // Filtrer les appareils Feeder
        final filtered = results.where(_isFeeder).toList();

        setState(() => _results = filtered);

        // Debug : afficher tous les appareils trouvés dans la console
        for (final r in results) {
          final name = _getDeviceName(r);
          if (name.isNotEmpty) {
            debugPrint('[SCAN] ${r.device.remoteId} : "$name" (RSSI: ${r.rssi})');
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur scan: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    setState(() => _scanning = false);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => _error = null);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Connexion en cours...'),
          ],
        ),
      ),
    );

    try {
      await _stopScan();
      await device.connect(timeout: const Duration(seconds: 10));

      // Découvrir services
      List<BluetoothService> services = await device.discoverServices();

      BluetoothCharacteristic? targetChar;

      for (var service in services) {
        for (var char in service.characteristics) {
          bool canWrite =
              char.properties.write || char.properties.writeWithoutResponse;
          bool canNotify = char.properties.notify;
          if (canWrite && canNotify) {
            targetChar = char;
            break;
          }
        }
        if (targetChar != null) break;
      }

      if (!mounted) return;
      Navigator.pop(context); // Fermer dialog

      if (targetChar == null) {
        _showSnackBar('Caracteristique BLE non trouvee', isError: true);
        await device.disconnect();
        return;
      }

      // Activer notifications
      await targetChar.setNotifyValue(true);

      // Demander un MTU plus grand (optionnel, pas bloquant)
      try {
        await device.requestMtu(512);
      } catch (_) {}

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnimalsPage(
            device: device,
            characteristic: targetChar!,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showSnackBar('Erreur connexion: $e', isError: true);
        try {
          await device.disconnect();
        } catch (_) {}
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Feeder - Scan BLE'),
      ),
      body: Column(
        children: [
          // Bouton scan
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _scanning ? _stopScan : _startScan,
                icon: Icon(
                    _scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? 'Arreter' : 'Scanner'),
                style: FilledButton.styleFrom(
                  backgroundColor: _scanning
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          ),

          if (_scanning) const LinearProgressIndicator(),

          // Erreur
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Liste résultats
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bluetooth,
                          size: 64,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _scanning
                              ? 'Recherche en cours...'
                              : 'Appuyez sur Scanner pour chercher\nles distributeurs Feeder',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      final name = _getDeviceName(result).isNotEmpty
                          ? _getDeviceName(result)
                          : 'Inconnu';
                      final rssi = result.rssi;

                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.primaryContainer,
                            child: Icon(
                              Icons.pets,
                              color:
                                  theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                          title: Text(name),
                          subtitle: Text(
                            '${result.device.remoteId} • RSSI: $rssi dBm',
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () =>
                              _connectToDevice(result.device),
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
