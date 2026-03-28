// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Page d'ajout d'un animal, avec formulaire de saisie et gestion du flux BLE
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../helpers/ration_helper.dart';

class AddAnimalPage extends StatefulWidget {
  final BluetoothCharacteristic characteristic;

  const AddAnimalPage({super.key, required this.characteristic});

  @override
  State<AddAnimalPage> createState() => _AddAnimalPageState();
}

class _AddAnimalPageState extends State<AddAnimalPage>
    with SingleTickerProviderStateMixin {
  // ─── Champs formulaire ───
  final _nameController = TextEditingController();
  String _type = 'chat';
  double _age = 3;
  double _weight = 4.0;
  bool _autoRecommend = true;
  double _cooldownSeconds = 28800;
  double _rationGrams = 50;

  // ─── États ───
  bool _saving = false;
  bool _waitingForRFID = false;
  String? _learnedRFID;

  // ─── BLE ───
  StreamSubscription? _notifySub;
  final StringBuffer _bleBuffer = StringBuffer();

  // ─── Animation scan RFID ───
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ─── Countdown RFID ───
  int _rfidCountdown = 60;
  Timer? _countdownTimer;

  // Limites poids
  double get _minWeight => _type == 'chat' ? 1.0 : 2.0;
  double get _maxWeight => _type == 'chat' ? 10.0 : 80.0;

  @override
  void initState() {
    super.initState();
    _startListening();
    _updateRecommendations();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  // ═══════════════════════════════════════
  // BLE - gère tout le flux de données
  // ═══════════════════════════════════════

  void _startListening() {
    _notifySub?.cancel();
    _bleBuffer.clear();

    _notifySub = widget.characteristic.onValueReceived.listen((value) {
      String chunk = utf8.decode(value, allowMalformed: true);
      _bleBuffer.write(chunk);

      String accumulated = _bleBuffer.toString();
      try {
        final data = jsonDecode(accumulated);
        _bleBuffer.clear();
        _handleResponse(data);
      } catch (_) {
        // dans le cas où le json est incomplet
      }
    });
  }

  void _handleResponse(dynamic data) {
    if (!mounted) return;

    if (data is Map<String, dynamic>) {
      // Passage à l'écran ajout rfid
      if (data['status'] == 'ok' && _saving && !_waitingForRFID) {
        _bleBuffer.clear(); 
        setState(() {
          _saving = false;
          _waitingForRFID = true;
        });
        _startRFIDCountdown();
        return;
      }

      // Une fois le rfid scannée
      if (data.containsKey('rfid_learned') && _waitingForRFID) {
        _countdownTimer?.cancel();
        final uid = data['rfid_learned'] ?? '';
        setState(() {
          _learnedRFID = uid;
          _waitingForRFID = false;
        });

        _showSnackBar('Badge RFID enregistre : $uid');
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) Navigator.pop(context, true);
        });
        return;
      }

      // gestion des erreurs
      if (data.containsKey('error')) {
        _countdownTimer?.cancel();
        setState(() {
          _saving = false;
          _waitingForRFID = false;
        });
        _showSnackBar(_translateError(data['error']), isError: true);
        return;
      }

      // réponse du distributeur après ajout d'animal (pour éviter de rester bloqué sur le loader)
      if (data.containsKey('animal') && data.containsKey('distributed')) {
        return;
      }
    }
  }

  // ═══════════════════════════════════════
  // Logique formulaire
  // ═══════════════════════════════════════

  String _translateError(String error) {
    switch (error) {
      case 'max_animals':
        return 'Nombre maximum d\'animaux atteint (4)';
      case 'name_required':
        return 'Le nom est obligatoire';
      case 'name_exists':
        return 'Ce nom existe deja';
      default:
        return 'Erreur: $error';
    }
  }

  // Met à jour les recommandations de ration et cooldown selon le profil
  void _updateRecommendations() {
    if (!_autoRecommend) return;
    int age = _age.round();
    _cooldownSeconds =
        RationHelper.recommendedCooldownSeconds(_type, age).toDouble();
    _rationGrams = RationHelper.rationPerMeal(
      _type,
      age,
      _weight,
      _cooldownSeconds.round(),
    ).toDouble();
  }
  void _onTypeChanged(String? type) {
    if (type == null) return;
    setState(() {
      _type = type;
      _weight = _weight.clamp(_minWeight, _maxWeight);
      _updateRecommendations();
    });
  }

  // ═══════════════════════════════════════
  // Sauvegarde
  // ═══════════════════════════════════════

// Envoie les données de l'animal au distributeur et gère le flux d'attente de la réponse
  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showSnackBar('Le nom est obligatoire', isError: true);
      return;
    }
    
    setState(() => _saving = true);
    _bleBuffer.clear();

    final command = {
      'cmd': 'add_animal',
      'name': name,
      'type': _type,
      'age': _age.round(),
      'weight': (_weight * 1000).round(),
      'ration': _rationGrams.round(),
      'cooldown': _cooldownSeconds.round(),
      'learn_rfid': true,
    };
// Envoi de la commande d'ajout d'animal add_animal
    try {
      await widget.characteristic.write(
        utf8.encode(jsonEncode(command)),
        withoutResponse: false,
      );

      // Timeout pour la réponse add_animal
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted && _saving && !_waitingForRFID) {
          setState(() => _saving = false);
          _showSnackBar('Timeout: pas de reponse', isError: true);
        }
      });   
    } catch (e) {
      setState(() => _saving = false);
      _showSnackBar('Erreur envoi: $e', isError: true);
    }
  }

  // ═══════════════════════════════════════
  // Durée RFID
  // ═══════════════════════════════════════

  void _startRFIDCountdown() {
    _rfidCountdown = 60;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _rfidCountdown--);

      if (_rfidCountdown <= 0) {
        timer.cancel();
        _skipRFID();
      }
    });
  }

  void _skipRFID() {
    _countdownTimer?.cancel();
    setState(() => _waitingForRFID = false);
    _showSnackBar('Animal enregistre sans badge RFID');
    Navigator.pop(context, true);
  }

  // ═══════════════════════════════════════
  // UI helpers
  // ═══════════════════════════════════════

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
    _nameController.dispose();
    _pulseController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════
  //   BUILD                                                       
  // ══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_saving) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ajouter un animal')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Enregistrement en cours...'),
            ],
          ),
        ),
      );
    }

    if (_waitingForRFID) {
      return _buildRFIDScanScreen();
    }

    return _buildFormScreen();
  }

  // ══════════════════════════════════════
  // Écran scan RFID
  // ══════════════════════════════════════

  Widget _buildRFIDScanScreen() {
    final theme = Theme.of(context);
    final name = _nameController.text.trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner le badge RFID'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icône animée
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _pulseAnimation.value,
                    child: child,
                  );
                },
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.contactless,
                    size: 64,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              Text(
                'Scannez le badge RFID',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 12),

              Text(
                'Approchez le badge du lecteur\npour l\'associer a "$name"',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),

              const SizedBox(height: 24),

              // Countdown
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: _rfidCountdown <= 10
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_rfidCountdown}s',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _rfidCountdown <= 10
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              const SizedBox(
                width: 200,
                child: LinearProgressIndicator(),
              ),

              const SizedBox(height: 40),

              TextButton.icon(
                onPressed: _skipRFID,
                icon: const Icon(Icons.skip_next),
                label: const Text('Passer (sans badge)'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  // Écran formulaire
  // ═══════════════════════════════════════

  Widget _buildFormScreen() {
    final theme = Theme.of(context);
    final int ageInt = _age.round();
    final double dailyNeed =
        RationHelper.dailyNeedGrams(_type, ageInt, _weight);

    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter un animal')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Nom ───
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nom',
                hintText: 'Ex: Minou, Rex...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.pets),
              ),
              textCapitalization: TextCapitalization.words,
            ),

            const SizedBox(height: 20),

            // ─── Type ───
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.category),
              ),
              items: const [
                DropdownMenuItem(value: 'chat', child: Text('🐱 Chat')),
                DropdownMenuItem(value: 'chien', child: Text('🐶 Chien')),
              ],
              onChanged: _onTypeChanged,
            ),

            const SizedBox(height: 24),

            // ─── Age ───
            _SliderSection(
              label: 'Age',
              value: RationHelper.formatAge(ageInt),
              slider: Slider(
                value: _age,
                min: 0,
                max: 25,
                divisions: 25,
                label: RationHelper.formatAge(ageInt),
                onChanged: (v) {
                  setState(() {
                    _age = v;
                    _updateRecommendations();
                  });
                },
              ),
            ),

            // ─── Poids ───
            _SliderSection(
              label: 'Poids',
              value: RationHelper.formatWeight(_weight),
              slider: Slider(
                value: _weight,
                min: _minWeight,
                max: _maxWeight,
                divisions: ((_maxWeight - _minWeight) * 2).round(),
                label: RationHelper.formatWeight(_weight),
                onChanged: (v) {
                  setState(() {
                    _weight = v;
                    _updateRecommendations();
                  });
                },
              ),
            ),

            const SizedBox(height: 8),

            // ─── Switch recommandations ───
            SwitchListTile(
              title: const Text('Recommandations automatiques'),
              subtitle:
                  const Text('Calcule ration et cooldown selon le profil'),
              value: _autoRecommend,
              onChanged: (v) {
                setState(() {
                  _autoRecommend = v;
                  if (v) _updateRecommendations();
                });
              },
            ),

            const SizedBox(height: 8),

            // ─── Cooldown ───
            _SliderSection(
              label: 'Cooldown',
              value: RationHelper.formatCooldown(_cooldownSeconds.round()),
              enabled: !_autoRecommend,
              slider: Slider(
                value: _cooldownSeconds,
                min: 60,
                max: 43200,
                divisions: 100,
                label:
                    RationHelper.formatCooldown(_cooldownSeconds.round()),
                onChanged: _autoRecommend
                    ? null
                    : (v) => setState(() => _cooldownSeconds = v),
              ),
            ),

            // ─── Ration ───
            _SliderSection(
              label: 'Ration par repas',
              value: RationHelper.formatRation(_rationGrams.round()),
              enabled: !_autoRecommend,
              slider: Slider(
                value: _rationGrams,
                min: 10,
                max: 200,
                divisions: 38,
                label: RationHelper.formatRation(_rationGrams.round()),
                onChanged: _autoRecommend
                    ? null
                    : (v) => setState(() => _rationGrams = v),
              ),
            ),

            const SizedBox(height: 8),

            // ─── Carte recommandations ───
            if (_autoRecommend)
              Card(
                color: theme.colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_awesome,
                              color: theme.colorScheme.onPrimaryContainer,
                              size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Recommandations',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color:
                                  theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _RecoRow('Categorie',
                          RationHelper.ageCategory(_type, ageInt)),
                      _RecoRow('Besoin journalier',
                          '${dailyNeed.round()}g'),
                      _RecoRow(
                        'Frequence',
                        '${RationHelper.formatCooldown(_cooldownSeconds.round())} '
                            '(${RationHelper.formatMealsPerDay(_cooldownSeconds.round())})',
                      ),
                      _RecoRow('Ration par repas',
                          RationHelper.formatRation(_rationGrams.round())),
                      const Divider(height: 16),
                      Text(
                        'Base sur : ${_type == 'chat' ? '🐱' : '🐶'} $_type, '
                        '${RationHelper.formatAge(ageInt)}, '
                        '${RationHelper.formatWeight(_weight)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer
                              .withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // ─── Info RFID ───
            Card(
              color: theme.colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.contactless,
                        color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Apres l\'enregistrement, vous devrez scanner '
                        'un badge RFID pour l\'associer a l\'animal.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ─── Bouton enregistrer ───
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Enregistrer et scanner RFID'),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════
// Widgets utilitaires
// ═══════════════════════════════════════

class _SliderSection extends StatelessWidget {
  final String label;
  final String value;
  final Widget slider;
  final bool enabled;

  const _SliderSection({
    required this.label,
    required this.value,
    required this.slider,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        enabled ? theme.colorScheme.onSurface : theme.colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style:
                      theme.textTheme.bodyMedium?.copyWith(color: color)),
              Text(value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  )),
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

class _RecoRow extends StatelessWidget {
  final String label;
  final String value;

  const _RecoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              )),
          Text(value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              )),
        ],
      ),
    );
  }
}
