#!/bin/bash

# --- VARIABLES GLOBALES (DOIT CORRESPONDRE AU SCRIPT D'INSTALLATION) ---
NGINX_SERVER_NAME=$(hostname -f)
NGINX_ROOT_DIR="/var/www/$NGINX_SERVER_NAME" # Racine du site Nginx (pour le site par défaut)
DIRECTUS_PROJECT_NAME="directus_mksoft"
DIRECTUS_INSTALL_PATH="/var/www/$DIRECTUS_PROJECT_NAME"
DIRECTUS_PORT=8055

# MySQL User & DB (Ces valeurs seront demandées ou extraites si possible)
MYSQL_DB_NAME="mksoft_db" # Nom par défaut si non spécifié

# Samba User & Share
SAMBA_SHARE_NAME="shared_data"
SAMBA_SHARE_PATH="/srv/$SAMBA_SHARE_NAME"

# --- Fonction pour afficher les messages d'erreur et quitter ---
function exit_on_error {
    echo -e "\n\e[31mERREUR: $1\e[0m" # Texte rouge
    exit 1
}

# --- Fonction de vérification (pour affichage seulement, ne quitte pas en cas d'échec de suppression) ---
function check_status {
    if [ $? -ne 0 ]; then
        echo -e "\e[31mÉCHEC: $1\e[0m" # Texte rouge pour échec
    else
        echo -e "\e[32mSUCCÈS: $2\e[0m" # Texte vert
    fi
}

# --- Fonction pour demander un mot de passe de manière sécurisée ---
function get_password {
    local prompt_msg="$1"
    local password_var="$2"
    while true; do
        read -sp "$prompt_msg: " entered_password
        echo
        if [[ -n "$entered_password" ]]; then
            eval "$password_var='$entered_password'"
            break
        else
            echo -e "\e[31mLe mot de passe ne peut pas être vide. Veuillez réessayer.\e[0m"
        fi
    done
}


echo -e "\e[34mDébut de la désinstallation/nettoyage des configurations précédentes...\e[0m"

# --- Vérification des privilèges ---
if [ "$EUID" -ne 0 ]; then
    exit_on_error "Ce script doit être exécuté avec des privilèges root (sudo)."
fi

# Obtenir le nom de l'utilisateur qui a exécuté le script d'installation (pour Samba)
# C'est l'utilisateur dont le mot de passe Samba a été défini.
CALLING_USER=$(logname)
echo "L'utilisateur système lié au script d'installation était : $CALLING_USER"

# --- AVERTISSEMENT GÉNÉRAL ---
echo -e "\n\e[31mATTENTION: Ce script vise à annuler les CONFIGURATIONS faites par le script d'installation précédent."
echo -e "Il s'efforcera de NE PAS supprimer les DONNÉES (fichiers de projet Directus, dossiers de partage Samba)."
echo -e "Cependant, pour MySQL, la base de données de Directus sera supprimée si elle existe, ce qui signifie la perte des données de Directus."
echo -e "Si vous souhaitez CONSERVER les données de votre base de données Directus, vous DEVEZ faire une SAUVEGARDE avant de continuer."
echo -e "Exemple: mysqldump -u <user> -p <database_name> > backup.sql\e[0m"
read -p "Voulez-vous vraiment continuer ? (tapez 'oui' pour confirmer) " -n 3 -r
echo
if [[ ! $REPLY =~ ^oui$ ]]; then
    echo -e "\e[33mOpération annulée par l'utilisateur.\e[0m"
    exit 0
fi

# --- 1. Nettoyage de Nginx ---
echo -e "\n--- 1. Nettoyage de Nginx ---"

echo "Suppression du lien symbolique Nginx pour Directus..."
if [ -L "/etc/nginx/sites-enabled/$DIRECTUS_PROJECT_NAME" ]; then
    rm -f "/etc/nginx/sites-enabled/$DIRECTUS_PROJECT_NAME"
    check_status "La suppression du lien symbolique Nginx pour Directus a échoué." "Lien symbolique Nginx Directus supprimé."
else
    echo "Lien symbolique Nginx Directus non trouvé."
fi

echo "Suppression du fichier de configuration Nginx pour Directus..."
if [ -f "/etc/nginx/sites-available/$DIRECTUS_PROJECT_NAME" ]; then
    rm -f "/etc/nginx/sites-available/$DIRECTUS_PROJECT_NAME"
    check_status "La suppression du fichier de configuration Nginx pour Directus a échoué." "Fichier de configuration Nginx Directus supprimé."
else
    echo "Fichier de configuration Nginx Directus non trouvé."
fi

echo "Suppression du lien symbolique Nginx et du fichier de configuration du site par défaut créé par le script..."
if [ -L "/etc/nginx/sites-enabled/$NGINX_SERVER_NAME" ]; then
    rm -f "/etc/nginx/sites-enabled/$NGINX_SERVER_NAME"
    check_status "La suppression du lien symbolique Nginx pour $NGINX_SERVER_NAME a échoué." "Lien symbolique Nginx $NGINX_SERVER_NAME supprimé."
fi
if [ -f "/etc/nginx/sites-available/$NGINX_SERVER_NAME" ]; then
    rm -f "/etc/nginx/sites-available/$NGINX_SERVER_NAME"
    check_status "La suppression du fichier de configuration Nginx pour $NGINX_SERVER_NAME a échoué." "Fichier de configuration Nginx $NGINX_SERVER_NAME supprimé."
else
    echo "Fichier de configuration Nginx $NGINX_SERVER_NAME non trouvé."
fi


echo "Réactivation du lien symbolique Nginx 'default' si le fichier existe et n'est pas lié..."
# Le script d'installation supprime ce lien par défaut. Nous le recréons si nécessaire.
if [ ! -L "/etc/nginx/sites-enabled/default" ] && [ -f "/etc/nginx/sites-available/default" ]; then
    ln -s "/etc/nginx/sites-available/default" "/etc/nginx/sites-enabled/default"
    check_status "La recréation du lien symbolique Nginx 'default' a échoué." "Lien symbolique Nginx 'default' recréé."
else
    echo "Lien symbolique Nginx 'default' déjà présent ou son fichier source n'existe pas."
fi

echo "Vérification de la syntaxe Nginx et redémarrage..."
nginx -t &>/dev/null
if [ $? -ne 0 ]; then
    echo -e "\e[33mAvertissement: Erreur de syntaxe Nginx après la suppression des fichiers. Veuillez vérifier manuellement si Nginx peut démarrer.\e[0m"
    systemctl restart nginx || echo -e "\e[31mÉchec du redémarrage de Nginx. Veuillez vérifier le journal des erreurs de Nginx.\e[0m"
else
    systemctl restart nginx
    check_status "Le redémarrage de Nginx a échoué." "Nginx redémarré."
fi
echo -e "\e[32mNettoyage Nginx (configurations) terminé.\e[0m"


echo "Retrait des règles UFW pour Nginx..."
ufw delete allow 'Nginx Full' &>/dev/null
ufw delete allow 'Nginx HTTP' &>/dev/null # Au cas où
ufw delete allow 'Nginx HTTPS' &>/dev/null # Au cas où
check_status "" "Règles UFW Nginx retirées (si présentes)."

# --- 2. Nettoyage de Directus (services et UFW) ---
echo -e "\n--- 2. Nettoyage de Directus ---"

echo "Arrêt et désactivation du service Systemd Directus..."
systemctl stop directus &>/dev/null
systemctl disable directus &>/dev/null
check_status "L'arrêt/désactivation du service Directus a échoué (peut-être non actif)." "Service Directus arrêté et désactivé."

echo "Suppression du fichier de service Systemd Directus..."
DIRECTUS_SERVICE_FILE="/etc/systemd/system/directus.service"
if [ -f "$DIRECTUS_SERVICE_FILE" ]; then
    rm -f "$DIRECTUS_SERVICE_FILE"
    check_status "La suppression du fichier de service Systemd Directus a échoué." "Fichier de service Systemd Directus supprimé."
else
    echo "Fichier de service Systemd Directus non trouvé."
fi

echo "Rechargement des configurations Systemd..."
systemctl daemon-reload
check_status "Le rechargement des daemons Systemd a échoué." "Configurations Systemd rechargées."

echo "Retrait de la règle UFW pour le port Directus ($DIRECTUS_PORT)..."
ufw delete allow "$DIRECTUS_PORT"/tcp &>/dev/null
check_status "" "Règle UFW Directus retirée (si présente)."

echo -e "\e[33mAvertissement: Le dossier du projet Directus ($DIRECTUS_INSTALL_PATH) et son contenu (y compris le fichier .env, les node_modules, etc.) NE SONT PAS supprimés, conformément à votre demande de conservation des données.\e[0m"
echo -e "\e[32mNettoyage Directus (services/UFW) terminé.\e[0m"

# --- 3. Nettoyage de MySQL (utilisateur et DB Directus uniquement) ---
echo -e "\n--- 3. Nettoyage de MySQL ---"

# Demander le mot de passe root MySQL pour se connecter
get_password "Veuillez entrer le mot de passe actuel de l'utilisateur root de MySQL" MYSQL_ROOT_PASSWORD_UNINSTALL

# Demander le nom d'utilisateur MySQL Directus pour le supprimer
read -p "Veuillez entrer le nom d'utilisateur MySQL qui a été créé pour Directus (e.g., mksoft_user) : " MYSQL_USER_TO_REMOVE
read -p "Veuillez confirmer le nom de la base de données Directus (e.g., mksoft_db) : " MYSQL_DB_NAME_TO_REMOVE

echo "Suppression de l'utilisateur MySQL '$MYSQL_USER_TO_REMOVE' et de la base de données '$MYSQL_DB_NAME_TO_REMOVE'..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD_UNINSTALL" -e "
DROP DATABASE IF EXISTS \`$MYSQL_DB_NAME_TO_REMOVE\`;
DROP USER IF EXISTS '$MYSQL_USER_TO_REMOVE'@'localhost';
FLUSH PRIVILEGES;
"
check_status "La suppression de l'utilisateur/base de données MySQL a échoué. Vérifiez le mot de passe root et les noms." "Utilisateur et base de données MySQL Directus supprimés."

echo -e "\e[32mNettoyage MySQL (utilisateur/DB Directus) terminé.\e[0m"

# --- 4. Nettoyage de Samba ---
echo -e "\n--- 4. Nettoyage de Samba ---"

echo "Suppression de la configuration du partage Samba dans smb.conf..."
SMB_CONF_FILE="/etc/samba/smb.conf"
SHARE_SECTION_START="\[$SAMBA_SHARE_NAME\]"

if grep -q "$SHARE_SECTION_START" "$SMB_CONF_FILE"; then
    # Utilise awk pour supprimer la section de partage et les lignes suivantes jusqu'à la prochaine section ou la fin du fichier.
    # Ceci est robuste pour supprimer des blocs de configuration.
    awk "/$SHARE_SECTION_START/{p=1;next}/^\\[/{p=0}!p" "$SMB_CONF_FILE" > "${SMB_CONF_FILE}.tmp" && \
    mv "${SMB_CONF_FILE}.tmp" "$SMB_CONF_FILE"
    check_status "La suppression de la section du partage Samba dans smb.conf a échoué." "Section du partage Samba supprimée de smb.conf."
else
    echo "Le partage Samba '$SAMBA_SHARE_NAME' n'est pas trouvé dans smb.conf."
fi

echo "Suppression de l'utilisateur Samba '$CALLING_USER'..."
# Supprime l'utilisateur Samba (qui est un utilisateur Samba, pas un utilisateur système)
if pdbedit -L -u "$CALLING_USER" &>/dev/null; then # Vérifie si l'utilisateur Samba existe
    smbpasswd -x "$CALLING_USER"
    check_status "La suppression de l'utilisateur Samba a échoué." "Utilisateur Samba '$CALLING_USER' supprimé."
else
    echo "L'utilisateur Samba '$CALLING_USER' n'est pas configuré dans Samba."
fi

echo "Redémarrage des services Samba..."
systemctl restart smbd nmbd
check_status "Le redémarrage de Samba a échoué." "Samba redémarré."

echo -e "\e[33mAvertissement: Le dossier de partage Samba ($SAMBA_SHARE_PATH) et son contenu NE SONT PAS supprimés, conformément à votre demande de conservation des données.\e[0m"
echo -e "\e[32mNettoyage Samba terminé.\e[0m"

# --- 5. Nettoyage UFW résiduel (règle SSH non touchée pour la sécurité) ---
echo -e "\n--- 5. Nettoyage UFW résiduel ---"
echo "La règle UFW pour SSH (port 22) n'est PAS retirée pour éviter de vous bloquer hors du serveur."
echo "Si vous souhaitez la retirer, exécutez manuellement: sudo ufw delete allow OpenSSH"
echo -e "\e[32mNettoyage UFW résiduel terminé.\e[0m"


echo -e "\n\e[35m--------------------------------------------------------\e[0m"
echo -e "\e[35mNettoyage des configurations précédentes terminé !\e[0m"
echo -e "\e[35m--------------------------------------------------------\e[0m"
echo "Récapitulatif des opérations :"
echo "  - Les configurations Nginx pour Directus et le site par défaut spécifique au script ont été supprimées."
echo "    Le site 'default' de Nginx a été réactivé si le fichier /etc/nginx/sites-available/default existe."
echo "  - Le service Systemd de Directus a été arrêté, désactivé et son fichier supprimé."
echo "    Le dossier du projet Directus ($DIRECTUS_INSTALL_PATH) et son contenu ont été CONSERVÉS."
echo "  - L'utilisateur MySQL et la base de données Directus ont été supprimés."
echo "    \e[31mATTENTION: Cela a entraîné la perte des données de Directus si aucune sauvegarde n'a été faite avant l'exécution.\e[0m"
echo "  - La configuration du partage Samba a été retirée et l'utilisateur Samba a été supprimé."
echo "    Le dossier de partage Samba ($SAMBA_SHARE_PATH) et son contenu ont été CONSERVÉS."
echo "  - Les règles UFW spécifiques à Nginx et Directus ont été retirées."
echo "  - Node.js, npm, MySQL Server et Samba ne sont PAS désinstallés."

echo -e "\nCe script a tenté d'annuler les configurations spécifiques tout en préservant au maximum les données existantes, là où c'était possible et sensé."
