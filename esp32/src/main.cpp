// ═══════════════════════════════════════════════════════════════════
// Auteur      : Moulin Rémi
// Projet      : Distributeur automatique pour animaux — SAÉ6.IOM.01
// Formation   : BUT Réseaux et Télécommunications — IUT de Blois
// Année       : 2026
// ───────────────────────────────────────────────────────────────────
// Description : Code principale de l'esp32, gérant la logique de distribution, les capteurs, et la communication MQTT/BLE.
// ═══════════════════════════════════════════════════════════════════
//
// *  Topics MQTT publiés :
// *    feeder/status        → "online" (retained, au démarrage)
// *    feeder/rfid_scan     → {animal, uid, timestamp}
// *    feeder/distributed   → {animal, requested, distributed, bowl, feeds, timestamp}
// *    feeder/bowl_weight   → {weight, timestamp}
// *    feeder/errors        → {type, animal, timestamp}
//
// Note : Certains commentaires de ce fichier sont générés
//        automatiquement par une extension VS Code.

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <NimBLEDevice.h>
#include <HX711.h>
#include <MFRC522.h>
#include <SPI.h>
#include <ESP32Servo.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <time.h>

#include "config.h"

// ═══════════════════════════════════════
// Objets globaux
// ═══════════════════════════════════════

WiFiClient   wifiClient;
PubSubClient mqttClient(wifiClient);
HX711        scale;
MFRC522      rfid(PIN_RFID_SS, PIN_RFID_RST);
Servo        servoMotor;
Preferences  prefs;

NimBLEServer*         bleServer         = nullptr;
NimBLECharacteristic* bleCharacteristic = nullptr;
bool bleConnected = false;

Animal       animals[MAX_ANIMALS];
uint8_t      animalCount = 0;
SystemConfig config;

bool wifiConnected = false;
bool mqttConnected = false;
bool ntpSynced     = false;
unsigned long lastWifiAttempt = 0;
unsigned long lastMQTTAttempt = 0;

String learningRFIDAnimalName = "";

// Distribution en boucle fermée
bool          distributing       = false;
uint8_t       distribAnimalIdx   = 0;
unsigned long distribStartTime   = 0;
unsigned long distribLastWeigh   = 0;   // dernier pesage pendant distribution
float         distribWeightBefore= 0;
float         distribTargetWeight= 0;   // poids cible dans la gamelle

// LED
LEDState      currentLEDState = LED_OFF;
unsigned long lastLEDBlink    = 0;

// ═══════════════════════════════════════
// Prototypes
// ═══════════════════════════════════════

void setupBLE();
void setupWiFi();
void setupMQTT();
void syncNTP();
void loadConfig();
void saveConfig();
void loadAnimals();
void saveAnimals();
void sendBLEResponse(const String& response);
void handleBLECommand(const String& command);
void startDistribution(uint8_t animalIndex);
void updateDistribution();
float readWeight();
int   readStock();
String readRFIDCard();
void setLED(LEDState state);
void updateLED();
void publishMQTT(const char* topic, const char* payload, bool retained = false);
void publishDistributionResult(Animal* animal, float distributed, float bowlWeight);
String getTimestamp();

// ═══════════════════════════════════════
// NTP / Horodatage
// ═══════════════════════════════════════

void syncNTP() {
    if (!wifiConnected) return;
    configTime(3600, 3600, "pool.ntp.org", "time.nist.gov");  // UTC+1, DST +1h (France)
    
    struct tm timeinfo;
    if (getLocalTime(&timeinfo, 5000)) {
        ntpSynced = true;
        Serial.println("[NTP] Heure synchronisee");
    } else {
        Serial.println("[NTP] Echec synchronisation");
    }
}

/// Retourne un horodatage ISO 8601 si NTP dispo, sinon millis
String getTimestamp() {
    if (ntpSynced) {
        struct tm timeinfo;
        if (getLocalTime(&timeinfo, 100)) {
            char buf[30];
            strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &timeinfo);
            return String(buf);
        }
    }
    // Fallback : secondes depuis boot
    return "uptime_" + String(millis() / 1000);
}

// ═══════════════════════════════════════
// Callbacks BLE — NimBLE v2
// ═══════════════════════════════════════

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
        bleConnected = true;
        setLED(LED_BLUE);
        Serial.println("[BLE] Client connecte");
    }

    void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
        bleConnected = false;
        setLED(LED_OFF);
        Serial.printf("[BLE] Client deconnecte (reason=%d)\n", reason);
        NimBLEDevice::startAdvertising();
    }
};

class CharacteristicCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
        std::string value = pCharacteristic->getValue();
        if (value.length() > 0) {
            String command = String(value.c_str());
            Serial.println("[BLE] RX: " + command);
            handleBLECommand(command);
        }
    }
};

// ═══════════════════════════════════════════════════════════════
//   SETUP                                                       
// ═══════════════════════════════════════════════════════════════
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== DISTRIBUTEUR v6.0 ===\n");

    pinMode(PIN_LED_RED,   OUTPUT);
    pinMode(PIN_LED_GREEN, OUTPUT);
    pinMode(PIN_LED_BLUE,  OUTPUT);
    setLED(LED_OFF);

    pinMode(PIN_PIR, INPUT);

    pinMode(PIN_ULTRASONIC_TRIG, OUTPUT);
    pinMode(PIN_ULTRASONIC_ECHO, INPUT);

    // Balance HX711
    Serial.println("[HX711] Initialisation...");
    scale.begin(PIN_HX711_DOUT, PIN_HX711_SCK);
    if (scale.wait_ready_timeout(2000)) {
        scale.set_scale(CALIBRATION_FACTOR);
        scale.tare();
        Serial.println("[HX711] Balance taree OK");
    } else {
        Serial.println("[HX711] ATTENTION: balance non detectee, poursuite sans balance");
    }

    // RFID
    Serial.println("[RFID] Initialisation...");
    SPI.begin();
    rfid.PCD_Init();
    delay(100);
    byte v = rfid.PCD_ReadRegister(rfid.VersionReg);
    if (v == 0x00 || v == 0xFF) {
        Serial.println("[RFID] ERREUR: module non detecte !");
    } else {
        Serial.printf("[RFID] OK (firmware v0x%02X)\n", v);
    }

    // Servo
    servoMotor.attach(PIN_SERVO);
    servoMotor.write(90);
    Serial.println("[SERVO] OK");

    // Config & animaux
    prefs.begin("feeder", false);
    loadConfig();
    loadAnimals();

    // BLE
    setupBLE();

    // WiFi
    if (strlen(config.wifiSSID) > 0) {
        setupWiFi();
        if (wifiConnected) syncNTP();
    }

    Serial.println("\n=== Systeme pret ===\n");
}

// ═══════════════════════════════════════════════════════════════
//   LOOP                                                        
// ═══════════════════════════════════════════════════════════════

void loop() {
    static unsigned long lastRFIDCheck = 0;

    updateLED();

    // Distribution en boucle fermée (pesée continue)
    if (distributing) {
        updateDistribution();
    }

    // WiFi
    if (strlen(config.wifiSSID) > 0) {
        bool nowConnected = (WiFi.status() == WL_CONNECTED);
        if (nowConnected != wifiConnected) {
            wifiConnected = nowConnected;
            if (wifiConnected) {
                Serial.println("[WIFI] Connecte : " + WiFi.localIP().toString());
                if (!ntpSynced) syncNTP();
                if (config.mqttEnabled) setupMQTT();
            } else {
                Serial.println("[WIFI] Connexion perdue");
                mqttConnected = false;
            }
        }
        if (!wifiConnected && millis() - lastWifiAttempt > 30000) {
            WiFi.begin(config.wifiSSID, config.wifiPassword);
            lastWifiAttempt = millis();
        }
    }

    // MQTT
    if (config.mqttEnabled && wifiConnected && !mqttConnected
        && millis() - lastMQTTAttempt > 30000) {  // 30s entre tentatives (pas 10s)
        setupMQTT();
        lastMQTTAttempt = millis();
    }
    if (mqttConnected) mqttClient.loop();

    // ── Envoi périodique MQTT (poids gamelle + stock) ──
    static unsigned long lastMQTTPublish = 0;
    if (mqttConnected && !distributing && millis() - lastMQTTPublish > MQTT_PUBLISH_INTERVAL_MS) {
        lastMQTTPublish = millis();

        float bowl = readWeight();
        int stock = readStock();
        String ts = getTimestamp();

        char msg[200];
        snprintf(msg, sizeof(msg),
            "{\"weight\":%.1f,\"stock\":%d,\"ts\":\"%s\"}",
            (bowl >= 0) ? bowl : 0.0f, stock, ts.c_str());
        publishMQTT("feeder/bowl_weight", msg);
    }

    // PIR + RFID (toutes les 100ms, pas pendant distribution)
    if (!distributing && millis() - lastRFIDCheck > 100) {
        lastRFIDCheck = millis();

        if (digitalRead(PIN_PIR) == HIGH) {
            setLED(LED_YELLOW);

            String uid = readRFIDCard();
            if (uid.length() > 0) {
                Serial.println("[RFID] Badge lu : " + uid);

                // Mode apprentissage
                if (learningRFIDAnimalName.length() > 0) {
                    bool learned = false;
                    for (uint8_t i = 0; i < animalCount; i++) {
                        if (strcmp(animals[i].name, learningRFIDAnimalName.c_str()) == 0) {
                            strncpy(animals[i].rfidUID, uid.c_str(), sizeof(animals[i].rfidUID) - 1);
                            animals[i].rfidUID[sizeof(animals[i].rfidUID) - 1] = '\0';
                            saveAnimals();
                            Serial.println("[RFID] Badge enregistre pour : " + learningRFIDAnimalName);
                            sendBLEResponse("{\"rfid_learned\":\"" + uid + "\"}");
                            learningRFIDAnimalName = "";
                            setLED(LED_GREEN_SOLID);
                            delay(1000);
                            learned = true;
                            break;
                        }
                    }
                    if (!learned) learningRFIDAnimalName = "";

                // Mode normal
                } else {
                    bool found = false;
                    for (uint8_t i = 0; i < animalCount; i++) {
                        if (!animals[i].active) continue;
                        if (strcmp(animals[i].rfidUID, uid.c_str()) != 0) continue;

                        found = true;

                        // Publier le scan RFID sur MQTT (horodatage)
                        char scanMsg[256];
                        String ts = getTimestamp();
                        snprintf(scanMsg, sizeof(scanMsg),
                            "{\"animal\":\"%s\",\"uid\":\"%s\",\"ts\":\"%s\"}",
                            animals[i].name, uid.c_str(), ts.c_str());
                        publishMQTT("feeder/rfid_scan", scanMsg);

                        unsigned long elapsed = (millis() - animals[i].lastFeedTime) / 1000;

                        if (animals[i].lastFeedTime == 0 || elapsed >= animals[i].cooldownSeconds) {
                            setLED(LED_GREEN_SOLID);
                            delay(200);
                            startDistribution(i);
                        } else {
                            unsigned long reste = animals[i].cooldownSeconds - elapsed;
                            Serial.printf("[FEED] Cooldown %s : %lu sec\n", animals[i].name, reste);
                            setLED(LED_RED_SOLID);
                            delay(1000);
                        }
                        break;
                    }

                    if (!found) {
                        Serial.println("[RFID] Badge inconnu : " + uid);
                        setLED(LED_RED_BLINK);
                        delay(1000);
                    }
                }
            }

        } else {
            if (currentLEDState == LED_YELLOW || currentLEDState == LED_RED_SOLID) {
                setLED(bleConnected ? LED_BLUE : LED_OFF);
            }
        }
    }

    delay(10);
}

// ═══════════════════════════════════════════════════════════════
//   BLE                                                         
// ═══════════════════════════════════════════════════════════════

void setupBLE() {
    Serial.println("[BLE] Initialisation...");
    NimBLEDevice::init(BLE_DEVICE_NAME);
    // MTU sera négocié automatiquement par NimBLE lors de la connexion

    bleServer = NimBLEDevice::createServer();
    bleServer->setCallbacks(new ServerCallbacks());

    NimBLEService* service = bleServer->createService(BLE_SERVICE_UUID);
    bleCharacteristic = service->createCharacteristic(
        BLE_CHARACTERISTIC_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY
    );
    bleCharacteristic->setCallbacks(new CharacteristicCallbacks());

    service->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(BLE_SERVICE_UUID);
    adv->start();

    Serial.printf("[BLE] %s pret, advertising demarre\n", BLE_DEVICE_NAME);
}

void sendBLEResponse(const String& response) {
    if (!bleConnected || !bleCharacteristic) return;

    Serial.printf("[BLE] TX (%d octets)\n", response.length());

    if ((int)response.length() <= BLE_FRAGMENT_SIZE) {
        bleCharacteristic->setValue(response.c_str());
        bleCharacteristic->notify();
        return;
    }

    int len = response.length();
    int offset = 0;
    while (offset < len) {
        int chunkSize = min(BLE_FRAGMENT_SIZE, len - offset);
        String chunk = response.substring(offset, offset + chunkSize);
        bleCharacteristic->setValue(chunk.c_str());
        bleCharacteristic->notify();
        delay(20);
        offset += chunkSize;
    }
}

// ═══════════════════════════════════════════════════════════════
//   COMMANDES BLE                                               
// ═══════════════════════════════════════════════════════════════

void handleBLECommand(const String& command) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, command);

    if (err) {
        Serial.printf("[JSON] Erreur parse : %s\n", err.c_str());
        sendBLEResponse("{\"error\":\"invalid_json\"}");
        return;
    }

    const char* cmd = doc["cmd"];
    if (!cmd) {
        sendBLEResponse("{\"error\":\"no_cmd\"}");
        return;
    }

    // ─────────── get_all ───────────
    if (strcmp(cmd, "get_all") == 0) {
        JsonDocument resp;

        resp["s"]  = readStock();
        resp["wi"] = wifiConnected;
        resp["mq"] = mqttConnected;

        // Poids actuel dans la gamelle
        float bowl = readWeight();
        resp["bw"] = (bowl >= 0) ? (int)(bowl + 0.5f) : 0;

        JsonArray arr = resp["al"].to<JsonArray>();
        for (uint8_t i = 0; i < animalCount; i++) {
            JsonObject obj = arr.add<JsonObject>();
            obj["n"]  = animals[i].name;
            obj["t"]  = animals[i].type;
            obj["a"]  = animals[i].age;
            obj["w"]  = animals[i].weightGrams;
            obj["r"]  = animals[i].rationGrams;
            obj["c"]  = animals[i].cooldownSeconds;
            obj["id"] = animals[i].rfidUID;
            obj["f"]  = animals[i].feedCount;
        }

        String out;
        serializeJson(resp, out);
        Serial.printf("[BLE] get_all: %d octets\n", out.length());
        sendBLEResponse(out);
    }

    // ─────────── add_animal ───────────
    else if (strcmp(cmd, "add_animal") == 0) {
        if (animalCount >= MAX_ANIMALS) {
            sendBLEResponse("{\"error\":\"max_animals\"}");
            return;
        }

        const char* name = doc["name"];
        if (!name || strlen(name) == 0) {
            sendBLEResponse("{\"error\":\"name_required\"}");
            return;
        }

        for (uint8_t i = 0; i < animalCount; i++) {
            if (strcmp(animals[i].name, name) == 0) {
                sendBLEResponse("{\"error\":\"name_exists\"}");
                return;
            }
        }

        Animal* a = &animals[animalCount];
        memset(a, 0, sizeof(Animal));

        strncpy(a->name, name, sizeof(a->name) - 1);
        const char* type = doc["type"] | "chat";
        strncpy(a->type, type, sizeof(a->type) - 1);

        a->age             = constrain((int)(doc["age"] | 3), 0, AGE_MAX_YEARS);
        a->weightGrams     = constrain((int)(doc["weight"] | 4000), WEIGHT_MIN_GRAMS, WEIGHT_MAX_GRAMS);
        a->rationGrams     = constrain((int)(doc["ration"] | 50), RATION_MIN_GRAMS, RATION_MAX_GRAMS);
        a->cooldownSeconds = constrain((long)(doc["cooldown"] | 28800), (long)COOLDOWN_MIN_SECONDS, (long)COOLDOWN_MAX_SECONDS);
        a->totalConsumedGrams = 0;
        a->feedCount    = 0;
        a->lastFeedTime = 0;
        a->active       = true;

        animalCount++;
        saveAnimals();

        Serial.printf("[ADD] %s (%s, %d ans, %.1fkg, %dg/repas, cooldown %ds)\n",
                     a->name, a->type, a->age, a->weightGrams / 1000.0,
                     a->rationGrams, a->cooldownSeconds);

        if (doc["learn_rfid"] | false) {
            learningRFIDAnimalName = String(name);
            Serial.println("[RFID] Mode apprentissage pour : " + learningRFIDAnimalName);
        }

        sendBLEResponse("{\"status\":\"ok\"}");
    }

    // ─────────── delete_animal ───────────
    else if (strcmp(cmd, "delete_animal") == 0) {
        const char* name = doc["name"];
        if (!name) { sendBLEResponse("{\"error\":\"name_required\"}"); return; }

        bool found = false;
        for (uint8_t i = 0; i < animalCount; i++) {
            if (strcmp(animals[i].name, name) == 0) {
                for (uint8_t j = i; j < animalCount - 1; j++)
                    animals[j] = animals[j + 1];
                animalCount--;
                memset(&animals[animalCount], 0, sizeof(Animal));
                saveAnimals();
                sendBLEResponse("{\"status\":\"ok\"}");
                found = true;
                break;
            }
        }
        if (!found) sendBLEResponse("{\"error\":\"not_found\"}");
    }

    // ─────────── feed_now (bypass cooldown) ───────────
    else if (strcmp(cmd, "feed_now") == 0) {
        const char* name = doc["name"];
        if (!name) { sendBLEResponse("{\"error\":\"name_required\"}"); return; }

        bool found = false;
        for (uint8_t i = 0; i < animalCount; i++) {
            if (strcmp(animals[i].name, name) == 0) {
                startDistribution(i);
                sendBLEResponse("{\"status\":\"feeding\"}");
                found = true;
                break;
            }
        }
        if (!found) sendBLEResponse("{\"error\":\"not_found\"}");
    }

    // ─────────── tare_scale ───────────
    else if (strcmp(cmd, "tare_scale") == 0) {
        scale.tare();
        sendBLEResponse("{\"status\":\"tared\"}");
    }

    // ─────────── set_wifi ───────────
    else if (strcmp(cmd, "set_wifi") == 0) {
        strncpy(config.wifiSSID,     doc["ssid"] | "",     sizeof(config.wifiSSID) - 1);
        strncpy(config.wifiPassword, doc["password"] | "", sizeof(config.wifiPassword) - 1);
        saveConfig();
        WiFi.disconnect();
        wifiConnected = false;
        mqttConnected = false;
        ntpSynced     = false;
        if (strlen(config.wifiSSID) > 0) setupWiFi();
        sendBLEResponse("{\"status\":\"ok\"}");
    }

    // ─────────── set_mqtt ───────────
    else if (strcmp(cmd, "set_mqtt") == 0) {
        strncpy(config.mqttServer,   doc["server"] | "",       sizeof(config.mqttServer) - 1);
        strncpy(config.mqttUser,     doc["user"] | "",         sizeof(config.mqttUser) - 1);
        strncpy(config.mqttPassword, doc["password"] | "",     sizeof(config.mqttPassword) - 1);
        config.mqttPort    = doc["port"] | 1883;
        config.mqttEnabled = doc["enabled"] | true;
        saveConfig();
        if (mqttConnected) { mqttClient.disconnect(); mqttConnected = false; }
        if (config.mqttEnabled && wifiConnected) setupMQTT();
        sendBLEResponse("{\"status\":\"ok\"}");
    }

    else {
        sendBLEResponse("{\"error\":\"unknown_cmd\"}");
    }
}

// ═══════════════════════════════════════════════════════════════
//   DISTRIBUTION — BOUCLE FERMÉE (pesée continue)              
// ═══════════════════════════════════════════════════════════════

void startDistribution(uint8_t animalIndex) {
    if (distributing) {
        Serial.println("[FEED] Distribution deja en cours");
        return;
    }

    Animal* animal = &animals[animalIndex];
    Serial.printf("[FEED] Debut pour %s : %dg demandes\n", animal->name, animal->rationGrams);

    setLED(LED_GREEN_BLINK);

    float bowlBefore = readWeight();
    if (bowlBefore < 0) {
        Serial.println("[FEED] ERREUR : balance timeout");
        char msg[200];
        snprintf(msg, sizeof(msg),
            "{\"type\":\"hx711_timeout\",\"animal\":\"%s\",\"ts\":\"%s\"}",
            animal->name, getTimestamp().c_str());
        publishMQTT("feeder/errors", msg);
        setLED(LED_RED_BLINK);
        return;
    }

    if (bowlBefore >= animal->rationGrams * 0.8f) {
        Serial.printf("[FEED] Gamelle deja remplie (%.1fg)\n", bowlBefore);
        setLED(bleConnected ? LED_BLUE : LED_OFF);
        return;
    }

    distribTargetWeight = (float)animal->rationGrams;
    distribWeightBefore = bowlBefore;
    distribAnimalIdx    = animalIndex;
    distribStartTime    = millis();
    distribLastWeigh    = millis();
    distributing        = true;

    servoMotor.write(SERVO_SPEED);
    Serial.printf("[FEED] Servo ON (%d), cible: %.0fg, gamelle: %.1fg\n",
                 SERVO_SPEED, distribTargetWeight, bowlBefore);
}

void updateDistribution() {
    if (!distributing) return;

    // ── Timeout de sécurité ──
    if (millis() - distribStartTime > DISTRIB_TIMEOUT_MS) {
        servoMotor.write(SERVO_STOP);
        distributing = false;
        Serial.println("[FEED] TIMEOUT SECURITE - servo arrete");

        Animal* animal = &animals[distribAnimalIdx];
        char msg[200];
        snprintf(msg, sizeof(msg),
            "{\"type\":\"distrib_timeout\",\"animal\":\"%s\",\"ts\":\"%s\"}",
            animal->name, getTimestamp().c_str());
        publishMQTT("feeder/errors", msg);
        setLED(LED_RED_BLINK);

        delay(800);
        float bowlNow = readWeight();
        if (bowlNow < 0) bowlNow = 0;
        float distributed = bowlNow - distribWeightBefore;
        if (distributed < 0) distributed = 0;

        animal->totalConsumedGrams += (uint32_t)distributed;
        animal->feedCount++;
        animal->lastFeedTime = millis();
        saveAnimals();

        publishDistributionResult(animal, distributed, bowlNow);
        return;
    }

    // ── Pesée périodique ──
    if (millis() - distribLastWeigh < DISTRIB_WEIGH_INTERVAL_MS) return;
    distribLastWeigh = millis();

    if (!scale.wait_ready_timeout(200)) return;
    float bowlNow = scale.get_units(3);  // Moyenne sur 3 lectures (anti-bruit)
    if (bowlNow < 0) bowlNow = 0;

    float progress = 0;
    if (distribTargetWeight > distribWeightBefore) {
        progress = (bowlNow - distribWeightBefore) / (distribTargetWeight - distribWeightBefore);
    }

    // Afficher seulement toutes les 500ms pour ne pas saturer la console
    static unsigned long lastPrint = 0;
    if (millis() - lastPrint > 500) {
        Serial.printf("[FEED] %.1fg / %.0fg (%.0f%%)\n",
                     bowlNow, distribTargetWeight, progress * 100);
        lastPrint = millis();
    }

    // ── Stop : 3 lectures consécutives au-dessus du seuil ──
    // Évite les faux positifs causés par un pic de vibration
    static uint8_t hitCount = 0;
    if (progress >= DISTRIB_STOP_PERCENT) {
        hitCount++;
    } else {
        hitCount = 0;
    }

    if (hitCount >= DISTRIB_CONFIRM_COUNT) {
        hitCount = 0;
        servoMotor.write(SERVO_STOP);
        distributing = false;

        Serial.println("[FEED] Servo arrete, stabilisation...");
        delay(DISTRIB_STABILIZE_MS);

        float bowlFinal = readWeight();
        if (bowlFinal < 0) bowlFinal = bowlNow;

        float distributed = bowlFinal - distribWeightBefore;
        if (distributed < 0) distributed = 0;

        Animal* animal = &animals[distribAnimalIdx];

        animal->totalConsumedGrams += (uint32_t)distributed;
        animal->feedCount++;
        animal->lastFeedTime = millis();
        saveAnimals();

        Serial.printf("[FEED] TERMINE : %.1fg distribues (gamelle: %.1fg, cible: %.0fg)\n",
                     distributed, bowlFinal, distribTargetWeight);

        publishDistributionResult(animal, distributed, bowlFinal);
        setLED(bleConnected ? LED_BLUE : LED_OFF);
    }
}

/// Publie le résultat de distribution sur MQTT + BLE
void publishDistributionResult(Animal* animal, float distributed, float bowlWeight) {
    String ts = getTimestamp();

    char mqttMsg[300];
    snprintf(mqttMsg, sizeof(mqttMsg),
        "{\"animal\":\"%s\",\"requested\":%d,\"distributed\":%.1f,"
        "\"bowl\":%.1f,\"feeds\":%d,\"ts\":\"%s\"}",
        animal->name, animal->rationGrams, distributed,
        bowlWeight, animal->feedCount, ts.c_str());
    publishMQTT("feeder/distributed", mqttMsg);

    // Aussi publier le poids de gamelle seul
    char bowlMsg[100];
    snprintf(bowlMsg, sizeof(bowlMsg),
        "{\"weight\":%.1f,\"ts\":\"%s\"}", bowlWeight, ts.c_str());
    publishMQTT("feeder/bowl_weight", bowlMsg);

    // Notifier l'app BLE
    if (bleConnected) {
        sendBLEResponse(String(mqttMsg));
    }
}

// ═══════════════════════════════════════════════════════════════
//   CAPTEURS                                                    
// ═══════════════════════════════════════════════════════════════

float readWeight() {
    if (!scale.wait_ready_timeout(500)) {
        return -1.0f;
    }
    float w = scale.get_units(10);  // Moyenne sur 10 lectures pour précision
    return max(w, 0.0f);
}

int readStock() {
    // Prendre 5 mesures et garder la médiane (filtre les rebonds)
    float readings[STOCK_NUM_READINGS];
    int validCount = 0;

    for (int i = 0; i < STOCK_NUM_READINGS; i++) {
        digitalWrite(PIN_ULTRASONIC_TRIG, LOW);
        delayMicroseconds(2);
        digitalWrite(PIN_ULTRASONIC_TRIG, HIGH);
        delayMicroseconds(10);
        digitalWrite(PIN_ULTRASONIC_TRIG, LOW);

        long duration = pulseIn(PIN_ULTRASONIC_ECHO, HIGH, 30000);
        if (duration > 0) {
            readings[validCount] = duration * 0.034f / 2.0f;
            validCount++;
        }
        delay(30); // pause entre mesures
    }

    if (validCount == 0) return 0;

    // Tri simple pour trouver la médiane
    for (int i = 0; i < validCount - 1; i++) {
        for (int j = i + 1; j < validCount; j++) {
            if (readings[j] < readings[i]) {
                float tmp = readings[i];
                readings[i] = readings[j];
                readings[j] = tmp;
            }
        }
    }

    float distanceCm = readings[validCount / 2]; // médiane

    // Plus la distance est petite, plus c'est rempli
    int percent = 100 - (int)((distanceCm / STOCK_MAX_HEIGHT_CM) * 100.0f);

    return constrain(percent, 0, 100);
}

String readRFIDCard() {
    if (!rfid.PICC_IsNewCardPresent()) return "";
    if (!rfid.PICC_ReadCardSerial())   return "";

    String uid = "";
    for (byte i = 0; i < rfid.uid.size; i++) {
        if (rfid.uid.uidByte[i] < 0x10) uid += "0";
        uid += String(rfid.uid.uidByte[i], HEX);
    }
    uid.toUpperCase();

    rfid.PICC_HaltA();
    rfid.PCD_StopCrypto1();
    return uid;
}

// ══════════════════════════════════════════════════════════════
//   WiFi / MQTT                                                 
// ══════════════════════════════════════════════════════════════

void setupWiFi() {
    Serial.printf("[WIFI] Connexion a '%s'...\n", config.wifiSSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(config.wifiSSID, config.wifiPassword);
    lastWifiAttempt = millis();

    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 10) {  // 5s max (pas 10s)
        delay(500);
        Serial.print(".");
        attempts++;
    }
    Serial.println();

    if (WiFi.status() == WL_CONNECTED) {
        wifiConnected = true;
        Serial.println("[WIFI] Connecte : " + WiFi.localIP().toString());
        syncNTP();
        if (config.mqttEnabled) setupMQTT();
    } else {
        wifiConnected = false;
        Serial.println("[WIFI] Echec (retry auto)");
    }
}

void setupMQTT() {
    if (!wifiConnected) return;
    mqttClient.setServer(config.mqttServer, config.mqttPort);
    mqttClient.setSocketTimeout(2);  // Max 2s de blocage (défaut = 15s !)
    lastMQTTAttempt = millis();

    Serial.printf("[MQTT] Tentative %s:%d...\n", config.mqttServer, config.mqttPort);

    String clientId = "Feeder_" + String((uint32_t)ESP.getEfuseMac(), HEX);
    bool connected = false;
    if (strlen(config.mqttUser) == 0) {
        connected = mqttClient.connect(clientId.c_str());
    } else {
        connected = mqttClient.connect(clientId.c_str(), config.mqttUser, config.mqttPassword);
    }

    if (connected) {
        mqttConnected = true;
        Serial.println("[MQTT] Connecte");
        publishMQTT("feeder/status", "online", true);
    } else {
        mqttConnected = false;
        Serial.printf("[MQTT] Echec (rc=%d)\n", mqttClient.state());
    }
}

void publishMQTT(const char* topic, const char* payload, bool retained) {
    if (!mqttConnected) return;
    Serial.printf("[MQTT] %s → %s\n", topic, payload);
    mqttClient.publish(topic, payload, retained);
}

// ═══════════════════════════════════════════════════════════════
//   PREFERENCES (NVS)                                           
// ═══════════════════════════════════════════════════════════════

void loadConfig() {
    String wifiSSID     = prefs.getString("wifi_ssid", DEFAULT_WIFI_SSID);
    String wifiPassword = prefs.getString("wifi_pass", DEFAULT_WIFI_PASSWORD);
    String mqttServer   = prefs.getString("mqtt_srv",  DEFAULT_MQTT_SERVER);
    String mqttUser     = prefs.getString("mqtt_user", DEFAULT_MQTT_USER);
    String mqttPassword = prefs.getString("mqtt_pass", DEFAULT_MQTT_PASSWORD);

#if FORCE_MQTT_FROM_CONFIG_H
    mqttServer   = DEFAULT_MQTT_SERVER;
    mqttUser     = DEFAULT_MQTT_USER;
    mqttPassword = DEFAULT_MQTT_PASSWORD;
#endif

    strncpy(config.wifiSSID, wifiSSID.c_str(), sizeof(config.wifiSSID) - 1);
    config.wifiSSID[sizeof(config.wifiSSID) - 1] = '\0';
    strncpy(config.wifiPassword, wifiPassword.c_str(), sizeof(config.wifiPassword) - 1);
    config.wifiPassword[sizeof(config.wifiPassword) - 1] = '\0';
    strncpy(config.mqttServer, mqttServer.c_str(), sizeof(config.mqttServer) - 1);
    config.mqttServer[sizeof(config.mqttServer) - 1] = '\0';
    strncpy(config.mqttUser, mqttUser.c_str(), sizeof(config.mqttUser) - 1);
    config.mqttUser[sizeof(config.mqttUser) - 1] = '\0';
    strncpy(config.mqttPassword, mqttPassword.c_str(), sizeof(config.mqttPassword) - 1);
    config.mqttPassword[sizeof(config.mqttPassword) - 1] = '\0';

    config.mqttPort            = prefs.getUInt("mqtt_port", DEFAULT_MQTT_PORT);
    config.mqttEnabled         = prefs.getBool("mqtt_en",   DEFAULT_MQTT_ENABLED);
#if FORCE_MQTT_FROM_CONFIG_H
    config.mqttPort            = DEFAULT_MQTT_PORT;
    config.mqttEnabled         = DEFAULT_MQTT_ENABLED;
#endif
    config.servoGramsPerSecond = prefs.getFloat("servo_gps", 10.0f);
}

void saveConfig() {
    prefs.putString("wifi_ssid", config.wifiSSID);
    prefs.putString("wifi_pass", config.wifiPassword);
    prefs.putString("mqtt_srv",  config.mqttServer);
    prefs.putString("mqtt_user", config.mqttUser);
    prefs.putString("mqtt_pass", config.mqttPassword);
    prefs.putUInt  ("mqtt_port", config.mqttPort);
    prefs.putBool  ("mqtt_en",   config.mqttEnabled);
    prefs.putFloat ("servo_gps", config.servoGramsPerSecond);
}

void loadAnimals() {
    animalCount = prefs.getUInt("animal_count", 0);
    if (animalCount > MAX_ANIMALS) animalCount = MAX_ANIMALS;

    for (uint8_t i = 0; i < animalCount; i++) {
        String p = "a" + String(i) + "_";
        prefs.getString((p + "name").c_str(), animals[i].name,    sizeof(animals[i].name));
        prefs.getString((p + "type").c_str(), animals[i].type,    sizeof(animals[i].type));
        prefs.getString((p + "rfid").c_str(), animals[i].rfidUID, sizeof(animals[i].rfidUID));
        animals[i].age              = prefs.getUChar ((p + "age").c_str(),      0);
        animals[i].weightGrams      = prefs.getUShort((p + "weight").c_str(),   4000);
        animals[i].rationGrams      = prefs.getUShort((p + "ration").c_str(),   50);
        animals[i].cooldownSeconds  = prefs.getUInt  ((p + "cool").c_str(),     28800);
        animals[i].totalConsumedGrams = prefs.getUInt((p + "consumed").c_str(), 0);
        animals[i].feedCount        = prefs.getUShort((p + "feeds").c_str(),    0);
        animals[i].lastFeedTime     = 0;
        animals[i].active           = true;
    }
    Serial.printf("[NVS] %d animaux charges\n", animalCount);
}

void saveAnimals() {
    prefs.putUInt("animal_count", animalCount);
    for (uint8_t i = 0; i < animalCount; i++) {
        String p = "a" + String(i) + "_";
        prefs.putString((p + "name").c_str(),     animals[i].name);
        prefs.putString((p + "type").c_str(),     animals[i].type);
        prefs.putString((p + "rfid").c_str(),     animals[i].rfidUID);
        prefs.putUChar ((p + "age").c_str(),      animals[i].age);
        prefs.putUShort((p + "weight").c_str(),   animals[i].weightGrams);
        prefs.putUShort((p + "ration").c_str(),   animals[i].rationGrams);
        prefs.putUInt  ((p + "cool").c_str(),     animals[i].cooldownSeconds);
        prefs.putUInt  ((p + "consumed").c_str(), animals[i].totalConsumedGrams);
        prefs.putUShort((p + "feeds").c_str(),    animals[i].feedCount);
    }
}

// ═══════════════════════════════════════════════════════════════
//  LED                                                         
// ═══════════════════════════════════════════════════════════════

void setLED(LEDState state) {
    currentLEDState = state;
    lastLEDBlink    = millis();
    digitalWrite(PIN_LED_RED,   LOW);
    digitalWrite(PIN_LED_GREEN, LOW);
    digitalWrite(PIN_LED_BLUE,  LOW);

    switch (state) {
        case LED_BLUE:        digitalWrite(PIN_LED_BLUE, HIGH); break;
        case LED_YELLOW:      digitalWrite(PIN_LED_RED, HIGH); digitalWrite(PIN_LED_GREEN, HIGH); break;
        case LED_GREEN_SOLID: digitalWrite(PIN_LED_GREEN, HIGH); break;
        case LED_RED_SOLID:   digitalWrite(PIN_LED_RED, HIGH); break;
        default: break;
    }
}

void updateLED() {
    if (currentLEDState == LED_GREEN_BLINK && millis() - lastLEDBlink > 500) {
        lastLEDBlink = millis();
        static bool t = false; t = !t;
        digitalWrite(PIN_LED_GREEN, t); digitalWrite(PIN_LED_RED, LOW); digitalWrite(PIN_LED_BLUE, LOW);
    }
    if (currentLEDState == LED_RED_BLINK && millis() - lastLEDBlink > 250) {
        lastLEDBlink = millis();
        static bool t = false; t = !t;
        digitalWrite(PIN_LED_RED, t); digitalWrite(PIN_LED_GREEN, LOW); digitalWrite(PIN_LED_BLUE, LOW);
    }
}
