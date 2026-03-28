// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Page principale affichant la liste des animaux enregistrés, leurs informations,
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../helpers/ration_helper.dart';
import 'add_animal_page.dart';
import 'settings_page.dart';

class AnimalsPage extends StatefulWidget {
  final BluetoothDevice device;
  final BluetoothCharacteristic characteristic;

  const AnimalsPage({
    super.key,
    required this.device,
    required this.characteristic,
  });

  @override
  State<AnimalsPage> createState() => _AnimalsPageState();
}

class _AnimalsPageState extends State<AnimalsPage> {
  List<Map<String, dynamic>> _animals = [];
  bool _loading = true;
  bool _waitingResponse = false;

  StreamSubscription? _notifySub;
  StreamSubscription? _connectionSub;
  StringBuffer _bleBuffer = StringBuffer();
  Timer? _timeoutTimer;

  // Stats système
  int _stockPercent = -1;
  bool _wifiStatus = false;
  bool _mqttStatus = false;
  bool _statsLoaded = false;
  int _bowlWeight = 0;

  @override
  void initState() {
    super.initState();
    _startListening();
    _listenConnection();
    _loadAll();
  }

  // ═══════════════════════════════════════
  // BLE listener (exclusif)
  // ═══════════════════════════════════════

  void _startListening() {
    _notifySub?.cancel();
    _bleBuffer.clear();
    _waitingResponse = false;

    _notifySub = widget.characteristic.onValueReceived.listen((value) {
      String chunk = utf8.decode(value, allowMalformed: true);
      _bleBuffer.write(chunk);

      if (_bleBuffer.length > 4096) {
        _bleBuffer.clear();
        return;
      }

      String accumulated = _bleBuffer.toString();
      try {
        final data = jsonDecode(accumulated);
        _bleBuffer.clear();
        _handleResponse(data);
      } catch (_) {}
    });
  }

  void _stopListening() {
    _notifySub?.cancel();
    _notifySub = null;
    _bleBuffer.clear();
    _timeoutTimer?.cancel();
    _waitingResponse = false;
  }

  void _listenConnection() {
    _connectionSub = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        _showSnackBar('Connexion perdue', isError: true);
        Navigator.popUntil(context, (route) => route.isFirst);
      }
    });
  }

  // ═══════════════════════════════════════
  // Traitement des réponses
  // ═══════════════════════════════════════

  void _handleResponse(dynamic data) {
    if (!mounted) return;
    if (data is! Map<String, dynamic>) return;

    _timeoutTimer?.cancel();

    // ── Réponse get_all ──
    if (data.containsKey('al')) {
      final List raw = data['al'] ?? [];
      final animals = raw.map<Map<String, dynamic>>((item) {
        return {
          'name': item['n'] ?? '',
          'type': item['t'] ?? 'chat',
          'age': item['a'] ?? 0,
          'weight': item['w'] ?? 4000,
          'ration': item['r'] ?? 50,
          'cooldown': item['c'] ?? 28800,
          'rfid': item['id'] ?? '',
          'feeds': item['f'] ?? 0,
        };
      }).toList();

      setState(() {
        _animals = animals;
        _stockPercent = data['s'] ?? -1;
        _wifiStatus = data['wi'] ?? false;
        _mqttStatus = data['mq'] ?? false;
        _bowlWeight = data['bw'] ?? 0;
        _statsLoaded = true;
        _loading = false;
        _waitingResponse = false;
      });
      return;
    }

    // ── Réponse delete / tare : {"status":"ok"} ──
    if (data['status'] == 'ok') {
      _waitingResponse = false;
      _loadAll();
      return;
    }

    // ── Réponse feed_now : {"status":"feeding"} ──
    if (data['status'] == 'feeding') {
      _waitingResponse = false;
      _showSnackBar('Distribution lancee');
      return;
    }

    // ── Notification fin distribution (asynchrone) ──
    if (data.containsKey('animal') && data.containsKey('distributed')) {
      final name = data['animal'] ?? '';
      final grams = (data['distributed'] as num?)?.toStringAsFixed(0) ?? '?';
      _showSnackBar('$name : ${grams}g distribues');
      // Recharger pour mettre à jour le compteur de repas
      _loadAll();
      return;
    }

    // ── Erreur ──
    if (data.containsKey('error')) {
      setState(() {
        _loading = false;
        _waitingResponse = false;
      });
      _showSnackBar('Erreur: ${data['error']}', isError: true);
      return;
    }

    // Autre → ignorer
    _waitingResponse = false;
  }

  // ═══════════════════════════════════════
  // Commandes
  // ═══════════════════════════════════════

  Future<bool> _sendCommand(Map<String, dynamic> command) async {
    _bleBuffer.clear();
    try {
      await widget.characteristic.write(
        utf8.encode(jsonEncode(command)),
        withoutResponse: false,
      );
      return true;
    } catch (e) {
      if (mounted) _showSnackBar('Erreur envoi: $e', isError: true);
      return false;
    }
  }

  void _startTimeout(int seconds, String message) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && _waitingResponse) {
        setState(() {
          _loading = false;
          _waitingResponse = false;
        });
        _showSnackBar(message, isError: true);
      }
    });
  }

  Future<void> _loadAll() async {
    if (_waitingResponse) return;

    setState(() {
      _loading = true;
      _waitingResponse = true;
    });

    bool sent = await _sendCommand({'cmd': 'get_all'});
    if (!sent) {
      setState(() {
        _loading = false;
        _waitingResponse = false;
      });
      return;
    }

    _startTimeout(5, 'Timeout: pas de reponse');
  }

  // ═══════════════════════════════════════
  // Distribution forcée
  // ═══════════════════════════════════════

  Future<void> _forceFeed(String name, int rationGrams) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.restaurant, size: 32),
        title: const Text('Distribution forcee'),
        content: Text(
          'Distribuer ${rationGrams}g pour "$name" '
          'en ignorant le cooldown ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Distribuer'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _waitingResponse = true;
      await _sendCommand({'cmd': 'feed_now', 'name': name});
      _startTimeout(5, 'Timeout: pas de reponse (distribution)');
    }
  }

  // ═══════════════════════════════════════
  // Suppression
  // ═══════════════════════════════════════

  Future<void> _deleteAnimal(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer'),
        content: Text('Supprimer "$name" ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _loading = true;
        _waitingResponse = true;
      });
      await _sendCommand({'cmd': 'delete_animal', 'name': name});
      _startTimeout(5, 'Timeout suppression');
    }
  }

  // ═══════════════════════════════════════
  // Navigation (pause / resume)
  // ═══════════════════════════════════════

  Future<void> _navigateToAddAnimal() async {
    _stopListening();

    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddAnimalPage(
          characteristic: widget.characteristic,
        ),
      ),
    );

    if (!mounted) return;
    _startListening();
    if (added == true) _loadAll();
  }

  Future<void> _navigateToSettings() async {
    _stopListening();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          characteristic: widget.characteristic,
        ),
      ),
    );

    if (!mounted) return;
    _startListening();
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
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
    _notifySub?.cancel();
    _connectionSub?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  // ╔═══════════════════════════════════════════════════════════════╗
  // ║  BUILD                                                       ║
  // ╚═══════════════════════════════════════════════════════════════╝

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Animaux (${_animals.length}/3)'),
        leading: IconButton(
          icon: const Icon(Icons.bluetooth_disabled),
          tooltip: 'Deconnecter',
          onPressed: () async {
            _stopListening();
            await widget.device.disconnect();
            if (mounted) {
              Navigator.popUntil(context, (route) => route.isFirst);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recharger',
            onPressed: _waitingResponse ? null : _loadAll,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Parametres',
            onPressed: _navigateToSettings,
          ),
        ],
      ),
      floatingActionButton: _animals.length < 3
          ? FloatingActionButton.extended(
              onPressed: _navigateToAddAnimal,
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _StatusBox(
                  stockPercent: _stockPercent,
                  wifiConnected: _wifiStatus,
                  mqttConnected: _mqttStatus,
                  bowlWeight: _bowlWeight,
                  loaded: _statsLoaded,
                ),
                Expanded(
                  child: _animals.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.pets,
                                  size: 64,
                                  color: theme.colorScheme.outline),
                              const SizedBox(height: 16),
                              Text(
                                'Aucun animal enregistre',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Appuyez sur + pour en ajouter un',
                                style:
                                    theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _loadAll,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                16, 8, 16, 88),
                            itemCount: _animals.length,
                            itemBuilder: (context, index) {
                              final animal = _animals[index];
                              return _AnimalCard(
                                animal: animal,
                                onDelete: () =>
                                    _deleteAnimal(animal['name'] ?? ''),
                                onForceFeed: () => _forceFeed(
                                  animal['name'] ?? '',
                                  animal['ration'] ?? 50,
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

// ═══════════════════════════════════════
// Boîte de statut système
// ═══════════════════════════════════════

class _StatusBox extends StatelessWidget {
  final int stockPercent;
  final bool wifiConnected;
  final bool mqttConnected;
  final int bowlWeight;
  final bool loaded;

  const _StatusBox({
    required this.stockPercent,
    required this.wifiConnected,
    required this.mqttConnected,
    required this.bowlWeight,
    required this.loaded,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: !loaded
          ? const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatusItem(
                  icon: Icons.inventory_2,
                  label: 'Stock',
                  value: stockPercent >= 0 ? '$stockPercent%' : '--',
                  color: stockPercent < 20
                      ? theme.colorScheme.error
                      : stockPercent < 50
                          ? Colors.orange
                          : Colors.green,
                ),
                _StatusItem(
                  icon: Icons.scale,
                  label: 'Gamelle',
                  value: '${bowlWeight}g',
                  color: theme.colorScheme.primary,
                ),
                _StatusItem(
                  icon: wifiConnected ? Icons.wifi : Icons.wifi_off,
                  label: 'WiFi',
                  value: wifiConnected ? 'OK' : 'OFF',
                  color: wifiConnected
                      ? Colors.green
                      : theme.colorScheme.error,
                ),
                _StatusItem(
                  icon:
                      mqttConnected ? Icons.cloud_done : Icons.cloud_off,
                  label: 'MQTT',
                  value: mqttConnected ? 'OK' : 'OFF',
                  color: mqttConnected
                      ? Colors.green
                      : theme.colorScheme.error,
                ),
              ],
            ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatusItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 4),
        Text(value,
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.bold, color: color)),
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }
}

// ═══════════════════════════════════════
// Carte animal (avec bouton distribuer)
// ═══════════════════════════════════════

class _AnimalCard extends StatelessWidget {
  final Map<String, dynamic> animal;
  final VoidCallback onDelete;
  final VoidCallback onForceFeed;

  const _AnimalCard({
    required this.animal,
    required this.onDelete,
    required this.onForceFeed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final String name = animal['name'] ?? '?';
    final String type = animal['type'] ?? 'chat';
    final int age = animal['age'] ?? 0;
    final int rationGrams = animal['ration'] ?? 0;
    final int cooldownSec = animal['cooldown'] ?? 0;
    final int feeds = animal['feeds'] ?? 0;
    final int weightGrams = animal['weight'] ?? 4000;
    final String rfid = animal['rfid'] ?? '';

    final String emoji = type == 'chien' ? '🐶' : '🐱';
    final double weightKg = weightGrams / 1000.0;
    final bool hasRFID = rfid.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── En-tête ──
            Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(
                        '${type[0].toUpperCase()}${type.substring(1)} - '
                        '${RationHelper.formatAge(age)} - '
                        '${RationHelper.formatWeight(weightKg)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                if (hasRFID)
                  Tooltip(
                    message: 'Badge RFID : $rfid',
                    child: Icon(Icons.contactless,
                        size: 20, color: theme.colorScheme.primary),
                  )
                else
                  Tooltip(
                    message: 'Pas de badge RFID',
                    child: Icon(Icons.contactless,
                        size: 20,
                        color:
                            theme.colorScheme.outline.withOpacity(0.3)),
                  ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error),
                  onPressed: onDelete,
                  tooltip: 'Supprimer',
                ),
              ],
            ),

            const Divider(height: 20),

            // ── Infos ──
            Row(
              children: [
                _InfoChip(
                  icon: Icons.restaurant,
                  label: 'Ration',
                  value: RationHelper.formatRation(rationGrams),
                ),
                const SizedBox(width: 12),
                _InfoChip(
                  icon: Icons.timer,
                  label: 'Cooldown',
                  value: RationHelper.formatCooldown(cooldownSec),
                ),
                const SizedBox(width: 12),
                _InfoChip(
                  icon: Icons.check_circle_outline,
                  label: 'Repas',
                  value: '$feeds',
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── Bouton distribuer ──
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onForceFeed,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text('Distribuer ${rationGrams}g'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(value,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}
