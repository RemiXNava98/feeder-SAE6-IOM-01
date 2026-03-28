// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Page de paramètres pour configurer le WiFi, MQTT et tarer la balance du distributeur.
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class SettingsPage extends StatefulWidget {
  final BluetoothCharacteristic characteristic;

  const SettingsPage({super.key, required this.characteristic});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // WiFi
  final _ssidController = TextEditingController();
  final _wifiPassController = TextEditingController();

  // MQTT
  final _mqttServerController = TextEditingController();
  final _mqttPortController = TextEditingController(text: '1883');

  bool _sending = false;
  StreamSubscription? _notifySub;
  final StringBuffer _bleBuffer = StringBuffer();

  @override
  void initState() {
    super.initState();
    _listenBLE();
  }

  void _listenBLE() {
    _notifySub = widget.characteristic.onValueReceived.listen((value) {
      String chunk = utf8.decode(value, allowMalformed: true);
      _bleBuffer.write(chunk);

      String accumulated = _bleBuffer.toString();
      try {
        final data = jsonDecode(accumulated);
        _bleBuffer.clear();
        _handleResponse(data);
      } catch (_) {}
    });
  }

  void _handleResponse(dynamic data) {
    if (!mounted) return;
    setState(() => _sending = false);

    if (data is Map<String, dynamic>) {
      if (data['status'] == 'ok') {
        _showSnackBar('Configuration sauvegardée');
      } else if (data['status'] == 'tared') {
        _showSnackBar('Balance tarée');
      } else if (data.containsKey('error')) {
        _showSnackBar('Erreur: ${data['error']}', isError: true);
      }
    }
  }

  Future<void> _sendCommand(Map<String, dynamic> command) async {
    setState(() => _sending = true);
    _bleBuffer.clear();

    try {
      await widget.characteristic.write(
        utf8.encode(jsonEncode(command)),
        withoutResponse: false,
      );

      // Timeout
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted && _sending) {
          setState(() => _sending = false);
          _showSnackBar('Timeout: pas de réponse', isError: true);
        }
      });
    } catch (e) {
      setState(() => _sending = false);
      _showSnackBar('Erreur envoi: $e', isError: true);
    }
  }

  void _saveWifi() {
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty) {
      _showSnackBar('Le SSID est obligatoire', isError: true);
      return;
    }
    _sendCommand({
      'cmd': 'set_wifi',
      'ssid': ssid,
      'password': _wifiPassController.text,
    });
  }

  void _saveMQTT() {
    final server = _mqttServerController.text.trim();
    if (server.isEmpty) {
      _showSnackBar('L\'adresse du serveur est obligatoire', isError: true);
      return;
    }
    final port = int.tryParse(_mqttPortController.text) ?? 1883;
    _sendCommand({
      'cmd': 'set_mqtt',
      'server': server,
      'port': port,
      'user': 'feeder',
      'password': 'feeder',
      'enabled': true,
    });
  }

  void _tareScale() {
    _sendCommand({'cmd': 'tare_scale'});
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
    _ssidController.dispose();
    _wifiPassController.dispose();
    _mqttServerController.dispose();
    _mqttPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres'),
      ),
      body: _sending
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ─── WiFi ───
                  _SectionHeader(
                    icon: Icons.wifi,
                    title: 'WiFi',
                    theme: theme,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ssidController,
                    decoration: const InputDecoration(
                      labelText: 'SSID',
                      hintText: 'Nom du réseau WiFi',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.wifi),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _wifiPassController,
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe',
                      hintText: 'Mot de passe WiFi',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saveWifi,
                    icon: const Icon(Icons.save),
                    label: const Text('Sauvegarder WiFi'),
                  ),

                  const SizedBox(height: 32),

                  // ─── MQTT ───
                  _SectionHeader(
                    icon: Icons.cloud,
                    title: 'MQTT',
                    theme: theme,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _mqttServerController,
                    decoration: const InputDecoration(
                      labelText: 'Serveur IP',
                      hintText: 'Ex: 192.168.1.100',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dns),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _mqttPortController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '1883',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.numbers),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saveMQTT,
                    icon: const Icon(Icons.save),
                    label: const Text('Sauvegarder MQTT'),
                  ),

                  const SizedBox(height: 32),

                  // ─── Balance ───
                  _SectionHeader(
                    icon: Icons.scale,
                    title: 'Balance',
                    theme: theme,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _tareScale,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Tarer la balance'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final ThemeData theme;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary, size: 22),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
