## CREER NOUVEAU PROJET

```powershell
flutter create --org com.feeder --project-name feeder_app feeder_app
cd feeder_app
```


## INSTALLER DEPENDANCES

```powershell
flutter pub get
```

## COMPILER ANDROID

```powershell
flutter build apk --release
```


## Emplacement de l'apk
```
build\app\outputs\flutter-apk\app-release.apk
```

---

## COMPILER IOS (Mac uniquement)

```bash
flutter build ios --release
```

## Prérequis IOS
- Un Mac avec Xcode installé
- Un compte Apple Developer (gratuit pour pour les teste)

## Première fois
```bash
cd ios
pod install
cd ..
open ios/Runner.xcworkspace
```
Dans Xcode : sélectionner l'iPhone branché en USB, cliquer Run.

---

## INSTALLER

**Android : Copier l'apk sur le téléphone et lancer l'installation.**

**iOS : Installer via Xcode en branchant l'iPhone en USB.**


**Au premier lancement :**
1. Autoriser Bluetooth
2. Autoriser Localisation

**Puis :**
1. Cliquer "Scanner"
2. Sélectionner "Feeder_ESP32"

---

## EN CAS D'ERREUR

### SDK 36 not found (Android)

```
Android Studio → Tools → SDK Manager
Cocher "Android 15.0 (API 36)"
Apply
```

### Build failed (Android)

```powershell
cd android
gradlew clean
cd ..
flutter clean
flutter pub get
flutter build apk --release
```

### Build failed (iOS)

```bash
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
flutter clean
flutter pub get
flutter build ios --release
```

### Signing error (iOS)

```
Xcode → Runner → Signing & Capabilities
Sélectionner votre Team (compte Apple Developer)
```
