# Guide de Déploiement Directus sur Ubuntu 22.04 LTS

Ce dépôt contient un script Bash (`full_setup.sh`) conçu pour automatiser l'installation et la configuration de **Nginx**, **Node.js 22**, **MySQL**, **Samba**, et **Directus** sur un serveur **Ubuntu 22.04 LTS**.

---

## Table des Matières

1.  [Introduction](#1-introduction)
2.  [Fonctionnalités du Script](#2-fonctionnalités-du-script)
3.  [Prérequis](#3-prérequis)
4.  [Guide d'Utilisation](#4-guide-dutilisation)
    * [Étape 1: Préparation du Serveur](#étape-1-préparation-du-serveur)
    * [Étape 2: Téléchargement du Script](#étape-2-téléchargement-du-script)
    * [Étape 3: Vérification et Exécution](#étape-3-vérification-et-exécution)
5.  [Détails Techniques et Chemins](#5-détails-techniques-et-chemins)
6.  [Accès Post-Installation](#6-accès-post-installation)
7.  [Vérifications et Dépannage](#7-vérifications-et-dépannage)
8.  [Sécurité et Bonnes Pratiques (CRITIQUE POUR LA PRODUCTION)](#8-sécurité-et-bonnes-pratiques-critique-pour-la-production)

---

## 1. Introduction

Ce script est un outil d'automatisation puissant qui simplifie le déploiement d'un environnement de développement ou de production pour Directus. Il intègre les meilleures pratiques de configuration, y compris la gestion des utilisateurs, la configuration du pare-feu (`UFW`), et la mise en place d'un serveur web Nginx avec reverse proxy. Pour une sécurité accrue, il demande les mots de passe et autres informations sensibles de manière interactive.

---

## 2. Fonctionnalités du Script

Le script `full_setup.sh` réalise les opérations suivantes :

* **Vérification des Prérequis :** S'assure que l'utilisateur exécutant le script dispose des privilèges `sudo`.
* **Mise à jour Système :** Met à jour les listes de paquets et les paquets installés.
* **Installation d'Outils Essentiels :** Installe `curl`, `git`, `rsync`, `ufw`, et `openssl`.
* **Configuration de `UFW` (Uncomplicated Firewall) :** Active le pare-feu et autorise les connexions SSH, HTTP, HTTPS, et le port interne de Directus.
* **Installation et Configuration de Nginx :**
    * Installe Nginx et l'active au démarrage.
    * Crée une racine de site par défaut (`/var/www/NOM_HOTE_SERVEUR`).
    * Configure un `server block` Nginx utilisant le **nom d'hôte** du serveur comme `server_name`.
    * Met en place un **reverse proxy** pour Directus accessible via le chemin `/directus` (ex: `http://NOM_HOTE_SERVEUR/directus`), tout en permettant l'hébergement d'autres sites à la racine du domaine ou sur d'autres chemins.
* **Installation de Node.js 22 :** Ajoute le dépôt NodeSource et installe Node.js version 22 et `npm`.
* **Installation et Configuration de MySQL Server :**
    * Installe MySQL Server et l'active au démarrage.
    * **Automatise `mysql_secure_installation` :** Exécute les étapes de sécurisation par défaut.
    * Demande un **mot de passe root MySQL** si nécessaire.
    * Crée un utilisateur MySQL dédié et une base de données (`mksoft_db`) avec tous les privilèges requis pour Directus.
* **Installation et Configuration de Samba :**
    * Installe Samba pour le partage de fichiers en réseau.
    * Crée un répertoire de partage (`/srv/shared_data`).
    * Configure un partage Samba accessible par l'utilisateur exécutant le script et demande son **mot de passe Samba**.
* **Installation et Configuration de Directus :**
    * Crée le dossier d'installation Directus (`/var/www/directus_mksoft`).
    * Installe Directus CLI globalement.
    * Demande l'**e-mail** et le **mot de passe** de l'administrateur Directus.
    * Initialise et "bootstrappe" le projet Directus, en configurant la connexion à la base de données MySQL.
    * Génère des clés `KEY` et `SECRET` aléatoires et les stocke dans le fichier `.env` de Directus.
    * S'assure que Directus est exécuté sous l'utilisateur système qui a lancé le script via `sudo`.
* **Création d'un Service Systemd pour Directus :**
    * Crée un service Systemd (`directus.service`) pour s'assurer que Directus démarre automatiquement au boot et reste en ligne en arrière-plan.
* **Vérification d'État :** Inclut des vérifications à chaque étape pour s'assurer du succès des opérations.

---

## 3. Prérequis

Avant d'exécuter le script, assurez-vous que :

* Vous disposez d'un serveur **Ubuntu 22.04 LTS** (Live Server est recommandé).
* Vous avez un accès **SSH** au serveur.
* L'utilisateur avec lequel vous vous connectez dispose des privilèges **`sudo`**.

---

## 4. Guide d'Utilisation

### Étape 1: Préparation du Serveur

1.  **Connectez-vous à votre serveur** via SSH :
    ```bash
    ssh votre_utilisateur@votre_ip_serveur
    ```
2.  **Mettez à jour le système** (recommandé avant toute installation) :
    ```bash
    sudo apt update && sudo apt upgrade -y
    ```
3.  **Installez `curl`** si ce n'est pas déjà fait (le script en a besoin pour télécharger d'autres éléments) :
    ```bash
    sudo apt install -y curl
    ```

### Étape 2: Téléchargement du Script

1.  **Accédez à votre répertoire personnel** :
    ```bash
    cd ~
    ```
2.  **Téléchargez le script** `full_setup.sh` depuis votre dépôt GitHub.
    **N'oubliez pas de remplacer `votre_utilisateur` et `votre_depot` par les informations réelles de votre dépôt.**

    ```bash
    curl -o full_setup.sh [https://github.com/votre_utilisateur/votre_depot/raw/main/full_setup.sh](https://github.com/votre_utilisateur/votre_depot/raw/main/full_setup.sh)
    ```
    *L'option `-o full_setup.sh` enregistre le contenu téléchargé dans un fichier nommé `full_setup.sh`.*

### Étape 3: Vérification et Exécution

1.  **Vérifiez le contenu du script (CRITIQUE pour la sécurité!)** :
    **Avant d'exécuter avec `sudo`, lisez attentivement le script pour vous assurer qu'il est sûr et qu'il correspond à vos attentes.**

    ```bash
    less full_setup.sh # Pour lire le script (appuyez sur 'q' pour quitter)
    # ou
    cat full_setup.sh  # Pour afficher tout le script dans le terminal
    ```

2.  **Rendez le script exécutable** :
    ```bash
    chmod +x full_setup.sh
    ```

3.  **Exécutez le script avec `sudo`** :
    Le script vous guidera et vous demandera les informations nécessaires (mots de passe pour MySQL, Directus, Samba, etc.) à chaque étape.

    ```bash
    sudo ./full_setup.sh
    ```

---

## 5. Détails Techniques et Chemins

Voici un aperçu des emplacements clés configurés par le script :

* **Racine Nginx par défaut :** `/var/www/NOM_HOTE_SERVEUR`
* **Fichier de configuration Nginx :** `/etc/nginx/sites-available/NOM_HOTE_SERVEUR`
* **Chemin d'installation Directus :** `/var/www/directus_mksoft`
* **Fichier de service Systemd Directus :** `/etc/systemd/system/directus.service`
* **Chemin du partage Samba :** `/srv/shared_data`

---

## 6. Accès Post-Installation

Une fois le script exécuté avec succès :

* **Votre Site Web par Défaut :** Accédez à `http://NOM_HOTE_SERVEUR/` dans votre navigateur (remplacez `NOM_HOTE_SERVEUR` par le nom d'hôte de votre serveur).
* **L'Interface d'Administration Directus :** Naviguez vers `http://NOM_HOTE_SERVEUR/directus/admin`.
    * Utilisez l'email et le mot de passe d'administrateur Directus que vous avez saisis.
* **Partage Samba :**
    * **Depuis Windows :** Ouvrez l'Explorateur de fichiers et tapez `\\NOM_HOTE_SERVEUR\shared_data` dans la barre d'adresse.
    * **Depuis Linux/macOS :** Connectez-vous à `smb://NOM_HOTE_SERVEUR/shared_data`.
    * Utilisez le nom d'utilisateur et le mot de passe Samba que vous avez configurés pour l'utilisateur système qui a exécuté le script.

---

## 7. Vérifications et Dépannage

Utilisez ces commandes pour vérifier l'état des services et diagnostiquer d'éventuels problèmes :

* **Nginx :**
    ```bash
    sudo systemctl status nginx
    sudo nginx -t # Vérifie la syntaxe de configuration Nginx
    ```
* **MySQL :**
    ```bash
    sudo systemctl status mysql
    mysql -u votre_utilisateur_directus -p mksoft_db # Tentez de vous connecter à la DB Directus
    ```
* **Directus Service :**
    ```bash
    sudo systemctl status directus
    sudo journalctl -u directus -f # Pour voir les logs en temps réel
    ```
* **Samba :**
    ```bash
    sudo systemctl status smbd nmbd
    testparm # Vérifie la configuration Samba
    ```
* **UFW (Pare-feu) :**
    ```bash
    sudo ufw status verbose
    ```

---

## 8. Sécurité et Bonnes Pratiques (CRITIQUE POUR LA PRODUCTION)

* **Changement de Mots de Passe :** **Changez IMMÉDIATEMENT tous les mots de passe** configurés (MySQL, Directus admin, Samba) une fois le déploiement terminé. Ne laissez jamais les mots de passe par défaut pour un environnement de production.
* **Fichier `.env` de Directus :** Le fichier `.env` de Directus (`/var/www/directus_mksoft/.env`) contient des informations sensibles. Assurez-vous que ses **permissions sont restrictives** (`chmod 600 /var/www/directus_mksoft/.env`) et que seul l'utilisateur Directus peut y accéder.
* **Clés `KEY` et `SECRET` de Directus :** Ces clés sont cruciales pour la sécurité des jetons d'authentification Directus. Le script les génère aléatoirement et les stocke dans le `.env`.
    * **Impact :** Si vous réexécutez le script, de nouvelles clés seront générées, ce qui invalidera les sessions utilisateur et les jetons d'authentification existants.
    * **Recommandation en Production :** Pour un environnement stable, générez ces clés une seule fois et stockez-les de manière persistante et sécurisée (par exemple, dans un gestionnaire de secrets ou en tant que variables d'environnement Systemd directement dans le fichier de service Directus, au lieu du `.env`).
* **Utilisateur Non-Root :** Le script exécute le service Directus sous l'utilisateur qui a lancé le script via `sudo`. C'est une bonne pratique. Pour une granularité maximale, vous pourriez créer un utilisateur système encore plus spécifique et limité.
* **Certificats SSL/TLS :** Pour une utilisation en production, il est **indispensable de sécuriser votre site avec HTTPS**. Utilisez `Certbot` avec Nginx pour obtenir et renouveler des certificats gratuits de Let's Encrypt :
    * ```bash
        sudo apt install certbot python3-certbot-nginx
        sudo certbot --nginx -d votre_nom_de_domaine.com # Nécessite un nom de domaine valide et pointant vers votre serveur.
        ```

---
