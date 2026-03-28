# Configuration Raspberry Pi 4

## Fichiers

| Fichier | Description |
|---|---|
| `schema.sql` | Crée la base de données, l'utilisateur et les 4 tables |
| `flows_nodered.json` | Flow Node-RED à importer (pont MQTT → MariaDB) |

## Base de données

```bash
sudo mariadb < schema.sql
```

Crée la base `feeder_db` avec l'utilisateur `feeder` / `feeder2025`.

## Node-RED

1. Ouvrir `http://<ip-du-rpi>:1880`
2. Menu ☰ → Import → coller le contenu de `flows_nodered.json`
3. Configurer le noeud MySQL : user `feeder`, password `feeder2025`, database `feeder_db`
4. Cliquer Deploy

## Grafana

Les panneaux ont été configurés manuellement dans l'interface Grafana.

1. Ouvrir `http://<ip-du-rpi>:3000` (login `admin` / `admin`)
2. Ajouter une datasource MySQL : `localhost:3306`, base `feeder_db`, user `feeder`
3. Créer un dashboard et ajouter les panneaux souhaités

## Ports

| Service | Port |
|---|---|
| Mosquitto | 1883 |
| Node-RED | 1880 |
| Grafana | 3000 |
| MariaDB | 3306 |
