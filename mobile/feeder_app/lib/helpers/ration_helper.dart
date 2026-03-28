/// Helper pour les calculs de ration et le formatage d'affichage.
class RationHelper {
  // ─── Catégories d'âge ───

  static String ageCategory(String type, int age) {
    if (type == 'chat') {
      if (age < 1) return 'Chaton';
      if (age <= 7) return 'Adulte';
      if (age <= 11) return 'Senior';
      return 'Très senior';
    } else {
      if (age < 1) return 'Chiot';
      if (age <= 7) return 'Adulte';
      if (age <= 10) return 'Senior';
      return 'Très senior';
    }
  }

  // ─── Pourcentage besoin journalier selon type et âge ───

  static double dailyPercentage(String type, int age) {
    if (type == 'chat') {
      if (age < 1) return 0.10;
      if (age <= 7) return 0.035;
      if (age <= 11) return 0.0275;
      return 0.02;
    } else {
      if (age < 1) return 0.08;
      if (age <= 7) return 0.0275;
      if (age <= 10) return 0.02;
      return 0.015;
    }
  }

  // ─── Cooldown recommandé en secondes ───

  static int recommendedCooldownSeconds(String type, int age) {
    if (type == 'chat') {
      if (age < 1) return 14400;     // 4h  → 6 repas/jour
      if (age <= 7) return 28800;    // 8h  → 3 repas/jour
      if (age <= 11) return 28800;   // 8h  → 3 repas/jour
      return 43200;                   // 12h → 2 repas/jour
    } else {
      if (age < 1) return 21600;     // 6h  → 4 repas/jour
      if (age <= 7) return 43200;    // 12h → 2 repas/jour
      if (age <= 10) return 43200;   // 12h → 2 repas/jour
      return 43200;                   // 12h → 2 repas/jour
    }
  }

  // ─── Besoin journalier en grammes ───

  static double dailyNeedGrams(String type, int age, double weightKg) {
    return weightKg * 1000 * dailyPercentage(type, age);
  }

  // ─── Nombre de repas par jour ───

  static double mealsPerDay(int cooldownSeconds) {
    if (cooldownSeconds <= 0) return 1;
    return 86400.0 / cooldownSeconds;
  }

  // ─── Ration par repas (en grammes) ───

  static int rationPerMeal(String type, int age, double weightKg, int cooldownSeconds) {
    double daily = dailyNeedGrams(type, age, weightKg);
    double meals = mealsPerDay(cooldownSeconds);
    if (meals <= 0) return 50;
    double ration = daily / meals;
    return ration.round().clamp(10, 200);
  }

  // ─── Formatage ───

  static String formatCooldown(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${(seconds / 60).round()}min';
    double hours = seconds / 3600.0;
    return '${hours.toStringAsFixed(1)}h';
  }

  static String formatRation(int grams) => '${grams}g';

  static String formatAge(int years) => '$years ans';

  static String formatWeight(double kg) => '${kg.toStringAsFixed(1)} kg';

  static String formatMealsPerDay(int cooldownSeconds) {
    double meals = mealsPerDay(cooldownSeconds);
    if (meals == meals.roundToDouble()) {
      return '${meals.round()} repas/jour';
    }
    return '${meals.toStringAsFixed(1)} repas/jour';
  }
}
