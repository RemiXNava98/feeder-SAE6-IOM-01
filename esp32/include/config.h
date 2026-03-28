// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Config
// ═══════════════════════════════════════════════════════════════════
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

#pragma once

#include <Arduino.h>

// ═══════════════════════════════════════
// Broches matérielles
// ═══════════════════════════════════════

// Balance HX711
#define PIN_HX711_DOUT      16
#define PIN_HX711_SCK       17

// Capteur ultrason (niveau stock)
#define PIN_ULTRASONIC_TRIG 32
#define PIN_ULTRASONIC_ECHO 33

// Servo vis sans fin
#define PIN_SERVO           13

// Détecteur de présence
#define PIN_PIR             14

// Lecteur RFID RC522
#define PIN_RFID_SS         5
#define PIN_RFID_RST        22

// LED RGB (indications visuelles)
#define PIN_LED_RED         25
#define PIN_LED_GREEN       26
#define PIN_LED_BLUE        27

// ═══════════════════════════════════════
// Configuration BLE
// ═══════════════════════════════════════

#define BLE_DEVICE_NAME         "Feeder_ESP32"
#define BLE_SERVICE_UUID        "12345678-1234-1234-1234-123456789012"
#define BLE_CHARACTERISTIC_UUID "87654321-4321-4321-4321-210987654321"
#define BLE_FRAGMENT_SIZE       500   // MTU 512 - 12 octets overhead

// ═══════════════════════════════════════
// Limites du système
// ═══════════════════════════════════════

#define MAX_ANIMALS             3
#define RATION_MIN_GRAMS        10
#define RATION_MAX_GRAMS        200
#define COOLDOWN_MIN_SECONDS    60      // 1 minute
#define COOLDOWN_MAX_SECONDS    43200   // 12 heures
#define AGE_MAX_YEARS           25
#define WEIGHT_MIN_GRAMS        1000    // 1 kg
#define WEIGHT_MAX_GRAMS        80000   // 80 kg

// ═══════════════════════════════════════
// Calibration balance
// ═══════════════════════════════════════

#define CALIBRATION_FACTOR      1003.97
#define STOCK_MAX_HEIGHT_CM     13.4
#define STOCK_NUM_READINGS      5       // nombre de mesures ultrason (médiane)

// ═══════════════════════════════════════
// Distribution
// ═══════════════════════════════════════

#define SERVO_STOP                  90      // valeur servo = arrêt
#define SERVO_SPEED                 120     // vitesse unique de distribution
#define DISTRIB_WEIGH_INTERVAL_MS   150     // pesée toutes les 150ms (get_units(3) prend ~100ms)
#define DISTRIB_TIMEOUT_MS          30000   // sécurité : 30s max
#define DISTRIB_STOP_PERCENT        0.90f   // arrêter à 90% (inertie complète les 10%)
#define DISTRIB_CONFIRM_COUNT       3       // 3 lectures consécutives au-dessus avant d'arrêter
#define DISTRIB_STABILIZE_MS        1500    // attente stabilisation après arrêt servo

// ═══════════════════════════════════════
// MQTT
// ═══════════════════════════════════════

#define MQTT_PUBLISH_INTERVAL_MS    60000   // envoi périodique toutes les 30s

// j'en peux plus de ce code 
#define DEFAULT_WIFI_SSID           ""
#define DEFAULT_WIFI_PASSWORD       ""
#define DEFAULT_MQTT_SERVER         "192.168.1.138"
#define DEFAULT_MQTT_PORT           1883
#define DEFAULT_MQTT_USER           ""
#define DEFAULT_MQTT_PASSWORD       ""
#define DEFAULT_MQTT_ENABLED        true

// Si true : ignore les valeurs MQTT sauvegardées en NVS et utilise celles ci-dessus.
// Utile si une mauvaise IP MQTT est enregistrée et bloque la connexion.
#define FORCE_MQTT_FROM_CONFIG_H    true

// ═══════════════════════════════════════
// Structures de données
// ═══════════════════════════════════════

struct Animal {
    char     name[32];
    char     type[8];          // "chat" ou "chien"
    uint8_t  age;              // 0-25 ans
    uint16_t weightGrams;      // poids de l'animal en grammes
    uint16_t rationGrams;      // ration par repas en grammes (10-200)
    uint32_t cooldownSeconds;  // temps entre repas en secondes (60-43200)
    char     rfidUID[16];      // UID du badge RFID associé
    uint32_t totalConsumedGrams;
    uint16_t feedCount;        // nombre de repas distribués
    unsigned long lastFeedTime;// millis() du dernier repas
    bool     active;
};

struct SystemConfig {
    char     wifiSSID[32];
    char     wifiPassword[64];
    char     mqttServer[64];
    uint16_t mqttPort;
    char     mqttUser[32];
    char     mqttPassword[32];
    bool     mqttEnabled;
    float    servoGramsPerSecond; // débit de la vis sans fin
};

// ═══════════════════════════════════════
// États LED
// ═══════════════════════════════════════

enum LEDState {
    LED_OFF,
    LED_BLUE,          // BLE connecté
    LED_YELLOW,        // Présence détectée (PIR)
    LED_GREEN_BLINK,   // Distribution en cours
    LED_GREEN_SOLID,   // Badge reconnu, ok
    LED_RED_SOLID,     // Cooldown actif
    LED_RED_BLINK      // Erreur
};
