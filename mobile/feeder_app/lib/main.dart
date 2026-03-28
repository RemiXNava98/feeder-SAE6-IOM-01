// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Point d'entrée de l'application Flutter, définissant la page d'accueil du projet.
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

import 'package:flutter/material.dart';
import 'pages/scan_page.dart';

void main() {
  runApp(const FeederApp());
}

class FeederApp extends StatelessWidget {
  const FeederApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Feeder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4A90D9),
        useMaterial3: true,
        brightness: Brightness.light,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF4A90D9),
        useMaterial3: true,
        brightness: Brightness.dark,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const ScanPage(),
    );
  }
}
