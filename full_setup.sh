#!/bin/bash

# --- VARIABLES GLOBALES ---
NGINX_SERVER_NAME=$(hostname -f) # Utilise le nom d'hôte complet du serveur
NGINX_ROOT_DIR="/var/www/$NGINX_SERVER_NAME" # Racine du site Nginx (pour le site par défaut)
DIRECTUS_PROJECT_NAME="directus_mksoft"
DIRECTUS_INSTALL_PATH="/var/www/$DIRECTUS_PROJECT_NAME"
DIRECTUS_PORT=8055 # Port interne de Directus

# MySQL User & DB
MYSQL_DB_NAME="mksoft_db"

# Samba User & Share (sera demandé à l'utilisateur)
SAMBA_SHARE_NAME="shared_data"
SAMBA_SHARE_PATH="/srv/$SAMBA_SHARE_NAME" # Chemin du partage Samba

# --- Fonction pour afficher les messages d'erreur et quitter ---
function exit_on_error {
    echo -e "\n\e[31mERREUR: $1\e[0m" # Texte rouge
    exit 1
}

# --- Fonction de vérification ---
function check_status {
    if [ $? -ne 0 ]; then
        exit_on_error "$1"
    else
        echo -e "\e[32mOK: $2\e[0m" # Texte vert
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

echo -e "\e[34mDébut de l'installation et de la configuration du serveur...\e[0m" # Texte bleu

# --- Vérification des privilèges et utilisateur ---
echo -e "\n--- Vérification des privilèges et de l'utilisateur ---"

# Obtenir le nom de l'utilisateur qui exécute le script avec sudo
CALLING_USER=$(logname)
echo "Le script est exécuté par l'utilisateur: $CALLING_USER"

# S'assurer que l'utilisateur a les droits sudo
if ! id -nG "$CALLING_USER" | grep -qw "sudo"; then
    echo -e "\e[31mL'utilisateur '$CALLING_USER' ne fait pas partie du groupe 'sudo'.\e[0m"
    echo -e "\e[31mVeuillez ajouter l'utilisateur au groupe 'sudo' ou vous connecter en tant que root.\e[0m"
    echo "Exemple: usermod -aG sudo $CALLING_USER"
    exit_on_error "Permissions insuffisantes pour l'utilisateur exécutant le script."
fi

# Créer un utilisateur spécifique pour Directus si différent de l'utilisateur appelant
DIRECTUS_RUN_USER=$CALLING_USER # Par défaut, utilise l'utilisateur appelant
if ! id -u "$DIRECTUS_RUN_USER" >/dev/null 2>&1; then
    echo "L'utilisateur '$DIRECTUS_RUN_USER' n'existe pas. Création de l'utilisateur '$DIRECTUS_RUN_USER'..."
    useradd -m -s /bin/bash "$DIRECTUS_RUN_USER" || exit_on_error "Échec de la création de l'utilisateur '$DIRECTUS_RUN_USER'."
    echo "Veuillez définir un mot de passe pour l'utilisateur '$DIRECTUS_RUN_USER' :"
    passwd "$DIRECTUS_RUN_USER" || exit_on_error "Échec de la définition du mot de passe pour '$DIRECTUS_RUN_USER'."
    usermod -aG www-data "$DIRECTUS_RUN_USER" || exit_on_error "Échec de l'ajout de '$DIRECTUS_RUN_USER' au groupe www-data."
    check_status "La création/vérification de l'utilisateur a échoué." "Utilisateur '$DIRECTUS_RUN_USER' prêt."
fi


# --- 1. Configuration initiale du serveur (Procédure DigitalOcean) ---
echo -e "\n--- Étape 1: Configuration initiale du serveur (Sécurité de base) ---"

echo "Mise à jour des paquets du système..."
apt update || exit_on_error "Échec de la mise à jour des listes de paquets."
apt upgrade -y || exit_on_error "Échec de la mise à niveau des paquets."
apt autoremove -y || exit_on_error "Échec de la suppression des paquets inutiles."
check_status "La mise à jour du système a échoué." "Mise à jour du système terminée."

echo "Installation des outils nécessaires (curl, git, rsync, ufw, openssl)..."
apt install -y curl git rsync ufw openssl || exit_on_error "Échec de l'installation des outils nécessaires."
check_status "L'installation des outils a échoué." "Outils nécessaires installés."

# Activer UFW (Uncomplicated Firewall)
echo "Activation du pare-feu UFW..."
ufw enable || exit_on_error "Échec de l'activation de UFW."
check_status "L'activation d'UFW a échoué." "UFW activé."

# Autoriser SSH
echo "Autorisation du port SSH (22) sur UFW..."
ufw allow OpenSSH || exit_on_error "Échec de l'autorisation de SSH sur UFW."
check_status "L'autorisation de SSH sur UFW a échoué." "Port SSH autorisé sur UFW."

echo -e "\e[32mÉtape 1 terminée: Configuration initiale du serveur.\e[0m"


# --- 2. Installation et configuration de Nginx ---
echo -e "\n--- Étape 2: Installation et configuration de Nginx ---"

echo "Installation de Nginx..."
apt install -y nginx || exit_on_error "Échec de l'installation de Nginx."
check_status "L'installation de Nginx a échoué." "Nginx installé."

echo "Autorisation de Nginx sur UFW (HTTP et HTTPS)..."
ufw allow 'Nginx Full' || exit_on_error "Échec de l'autorisation de Nginx sur UFW."
check_status "L'autorisation de Nginx sur UFW a échoué." "Nginx autorisé sur UFW."

echo "Création du dossier racine du site Nginx par défaut: $NGINX_ROOT_DIR..."
mkdir -p "$NGINX_ROOT_DIR" || exit_on_error "Échec de la création du dossier $NGINX_ROOT_DIR."
# Assurer que l'utilisateur de Nginx peut lire le contenu
chown -R www-data:www-data "$NGINX_ROOT_DIR"
chmod -R 755 "$NGINX_ROOT_DIR"
check_status "La création du dossier Nginx a échoué." "Dossier Nginx créé et permissions ajustées."

echo "Création du fichier de configuration Nginx pour le serveur par défaut ($NGINX_SERVER_NAME)..."
NGINX_DEFAULT_CONF_PATH="/etc/nginx/sites-available/$NGINX_SERVER_NAME"
cat <<EOL > "$NGINX_DEFAULT_CONF_PATH"
server {
        listen 80;
        listen [::]:80;

        root $NGINX_ROOT_DIR;
        index index.html index.htm index.nginx-debian.html;

        server_name $NGINX_SERVER_NAME;

        location / {
                try_files \$uri \$uri/ =404;
        }
}
EOL
check_status "La création du fichier de configuration Nginx a échoué." "Fichier de configuration Nginx par défaut créé."

echo "Création d'un lien symbolique pour le site par défaut..."
ln -sf "$NGINX_DEFAULT_CONF_PATH" "/etc/nginx/sites-enabled/" || exit_on_error "Échec de la création du lien symbolique Nginx."
check_status "La création du lien symbolique Nginx a échoué." "Lien symbolique Nginx créé."

echo "Suppression du lien symbolique du site par défaut de Nginx (si existant)..."
rm -f /etc/nginx/sites-enabled/default || check_status "La suppression du lien par défaut Nginx a échoué." "Lien par défaut Nginx supprimé (si existant)."

echo "Vérification de la syntaxe de configuration Nginx..."
nginx -t || exit_on_error "Erreur de syntaxe dans la configuration Nginx."
check_status "La vérification de la syntaxe Nginx a échoué." "Syntaxe Nginx correcte."

echo "Redémarrage de Nginx pour appliquer les changements..."
systemctl restart nginx || exit_on_error "Échec du redémarrage de Nginx."
systemctl enable nginx || exit_on_error "Échec de l'activation de Nginx au démarrage."
check_status "Le redémarrage de Nginx a échoué." "Nginx configuré et redémarré."

# Créer un fichier de test simple
echo "<h1>Bienvenue sur $NGINX_SERVER_NAME!</h1>" > "$NGINX_ROOT_DIR/index.html"
check_status "La création de la page d'accueil Nginx a échoué." "Page d'accueil Nginx test créée."

echo -e "\e[32mÉtape 2 terminée: Nginx installé et configuré.\e[0m"


# --- 3. Installation de Node.js 22 ---
echo -e "\n--- Étape 3: Installation de Node.js 22 ---"

echo "Ajout du dépôt NodeSource pour Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - || exit_on_error "Échec de l'ajout du dépôt NodeSource."
check_status "L'ajout du dépôt NodeSource a échoué." "Dépôt NodeSource ajouté."

echo "Installation de Node.js 22 et npm..."
apt install -y nodejs || exit_on_error "Échec de l'installation de Node.js 22."
check_status "L'installation de Node.js a échoué." "Node.js 22 installé."

echo "Vérification des versions de Node.js et npm..."
node_version=$(node -v)
npm_version=$(npm -v)
echo "Node.js version: $node_version"
echo "NPM version: $npm_version"

if [[ "$node_version" != v22.* ]]; then
    exit_on_error "La version de Node.js installée n'est pas la 22.x."
fi
check_status "La vérification des versions Node.js/NPM a échoué." "Versions Node.js/NPM vérifiées."

echo -e "\e[32mÉtape 3 terminée: Node.js 22 installé.\e[0m"


# --- 4. Installation et configuration de MySQL ---
echo -e "\n--- Étape 4: Installation et configuration de MySQL ---"

echo "Installation de MySQL Server..."
apt install -y mysql-server || exit_on_error "Échec de l'installation de MySQL Server."
check_status "L'installation de MySQL a échoué." "MySQL Server installé."

echo "Activation et démarrage de MySQL..."
systemctl enable mysql || exit_on_error "Échec de l'activation de MySQL au démarrage."
systemctl start mysql || exit_on_error "Échec du démarrage de MySQL."
check_status "Le démarrage de MySQL a échoué." "MySQL Server démarré."

echo "Exécution de 'mysql_secure_installation' de manière automatisée..."
# Cette partie est délicate et peut nécessiter une interaction si le mot de passe root n'est pas vide.
# Pour une automatisation complète, on suppose que le root n'a pas de mot de passe au début.
# Les réponses sont "No" pour validation des mots de passe, "Yes" pour suppression des utilisateurs anonymes,
# "Yes" pour désactiver la connexion root à distance, "Yes" pour supprimer la base de données de test,
# et "Yes" pour recharger les tables de privilèges.
# IMPORTANT: Si le mot de passe root est déjà défini, cette partie peut échouer ou demander le mot de passe.

# Tester si le root MySQL a déjà un mot de passe
MYSQL_ROOT_HAS_PASSWORD=$(mysql -u root -e "SELECT 1;" 2>&1 | grep -q "Access denied for user 'root'@'localhost'")

if [ "$MYSQL_ROOT_HAS_PASSWORD" == "0" ]; then
    echo "Le mot de passe root MySQL semble déjà défini. Veuillez le saisir pour mysql_secure_installation."
    get_password "Veuillez entrer le mot de passe root MySQL actuel" MYSQL_ROOT_PASSWORD
    mysql_secure_installation_command="mysql_secure_installation -p$MYSQL_ROOT_PASSWORD"
else
    echo "Le mot de passe root MySQL semble vide. Procédure sans mot de passe initial."
    mysql_secure_installation_command="mysql_secure_installation"
fi

# Automatisation des réponses pour mysql_secure_installation
# Cette séquence de `expect` est très spécifique et peut échouer si la version de MySQL ou la logique de `mysql_secure_installation` change.
# installe expect
apt install -y expect || exit_on_error "Échec de l'installation de 'expect'."

expect -c "
set timeout 10
spawn $mysql_secure_installation_command

expect \"Would you like to setup VALIDATE PASSWORD component?\"
send \"n\r\"

expect \"Change the root password?\"
send \"n\r\"

expect \"Remove anonymous users?\"
send \"y\r\"

expect \"Disallow root login remotely?\"
send \"y\r\"

expect \"Remove test database and access to it?\"
send \"y\r\"

expect \"Reload privilege tables now?\"
send \"y\r\"

expect eof
" || exit_on_error "Échec de l'automatisation de mysql_secure_installation. Veuillez le lancer manuellement si des erreurs persistent."
check_status "L'automatisation de mysql_secure_installation a échoué." "mysql_secure_installation automatisé avec succès."


echo "Configuration de l'utilisateur et de la base de données MySQL pour Directus..."

get_password "Veuillez entrer le nom d'utilisateur MySQL à créer pour Directus" MYSQL_USER
get_password "Veuillez entrer le mot de passe pour l'utilisateur MySQL '$MYSQL_USER'" MYSQL_PASSWORD

# Créer l'utilisateur, la base de données et accorder les privilèges
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB_NAME\`;
GRANT ALL PRIVILEGES ON \`$MYSQL_DB_NAME\`.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
" || exit_on_error "Échec de la création de l'utilisateur, de la base de données ou de l'octroi des privilèges MySQL."
check_status "La configuration de l'utilisateur/DB MySQL a échoué." "Utilisateur MySQL '$MYSQL_USER' et base de données '$MYSQL_DB_NAME' créés avec privilèges."

echo -e "\e[32mÉtape 4 terminée: MySQL installé et configuré.\e[0m"


# --- Installation et configuration de Samba ---
echo -e "\n--- Étape: Installation et configuration de Samba ---"
echo "Installation de Samba..."
apt install -y samba || exit_on_error "Échec de l'installation de Samba."
check_status "L'installation de Samba a échoué." "Samba installé."

echo "Création du dossier de partage Samba: $SAMBA_SHARE_PATH..."
mkdir -p "$SAMBA_SHARE_PATH" || exit_on_error "Échec de la création du dossier de partage Samba."
chown -R "$CALLING_USER":"$CALLING_USER" "$SAMBA_SHARE_PATH" # L'utilisateur appelant sera propriétaire du partage
chmod -R 775 "$SAMBA_SHARE_PATH"
check_status "La création du dossier de partage Samba a échoué." "Dossier de partage Samba créé."

echo "Ajout de l'utilisateur '$CALLING_USER' à Samba..."
(echo "$CALLING_USER_PASSWORD"; echo "$CALLING_USER_PASSWORD") | smbpasswd -a "$CALLING_USER" || exit_on_error "Échec de l'ajout de l'utilisateur Samba."
smbpasswd -e "$CALLING_USER" # Activer l'utilisateur Samba
check_status "L'ajout de l'utilisateur Samba a échoué." "Utilisateur Samba ajouté."

echo "Configuration du fichier smb.conf..."
# Sauvegarder la configuration originale
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak || exit_on_error "Échec de la sauvegarde de smb.conf."

# Ajouter le partage au fichier smb.conf
cat <<EOL >> /etc/samba/smb.conf

[$SAMBA_SHARE_NAME]
    path = $SAMBA_SHARE_PATH
    browseable = yes
    read only = no
    create mask = 0775
    directory mask = 0775
    valid users = $CALLING_USER
    force group = $CALLING_USER
EOL
check_status "La configuration de smb.conf a échoué." "Samba configuré."

echo "Redémarrage du service Samba..."
systemctl restart smbd nmbd || exit_on_error "Échec du redémarrage de Samba."
check_status "Le redémarrage de Samba a échoué." "Samba redémarré."

echo -e "\e[32mInstallation et configuration de Samba terminées.\e[0m"


# --- 5. Création du projet Directus ---
echo -e "\n--- Étape 5: Création du projet Directus ---"

echo "Création du dossier d'installation Directus: $DIRECTUS_INSTALL_PATH..."
mkdir -p "$DIRECTUS_INSTALL_PATH" || exit_on_error "Échec de la création du dossier Directus."
chown -R "$DIRECTUS_RUN_USER":"$DIRECTUS_RUN_USER" "$DIRECTUS_INSTALL_PATH"
chmod -R 755 "$DIRECTUS_INSTALL_PATH"
check_status "La création du dossier Directus a échoué." "Dossier Directus créé."

# Exécuter les commandes npm/directus en tant que DIRECTUS_RUN_USER
echo "Passage à l'utilisateur '$DIRECTUS_RUN_USER' pour l'installation de Directus..."
sudo -u "$DIRECTUS_RUN_USER" bash -c "
    echo 'Déplacement vers le dossier Directus...'
    cd \"$DIRECTUS_INSTALL_PATH\" || exit_on_error \"Échec du déplacement vers le dossier Directus.\"

    echo 'Installation de Directus CLI (si ce nest pas déjà fait)...'
    npm install -g directus@latest || exit_on_error \"Échec de l'installation de Directus CLI.\"

    echo 'Création du projet Directus \"$DIRECTUS_PROJECT_NAME\"...'

    # Demander les mots de passe pour l'administrateur Directus
    get_password \"Veuillez entrer l'email de l'administrateur Directus\" DIRECTUS_ADMIN_EMAIL
    get_password \"Veuillez entrer le mot de passe de l'administrateur Directus\" DIRECTUS_ADMIN_PASSWORD

    # Configuration des variables d'environnement pour l'installation Directus
    export DB_CLIENT=\"mysql\"
    export DB_HOST=\"localhost\"
    export DB_PORT=\"3306\"
    export DB_USER=\"$MYSQL_USER\"
    export DB_PASSWORD=\"$MYSQL_PASSWORD\"
    export DB_DATABASE=\"$MYSQL_DB_NAME\"
    export ADMIN_EMAIL=\"$DIRECTUS_ADMIN_EMAIL\"
    export ADMIN_PASSWORD=\"$DIRECTUS_ADMIN_PASSWORD\"

    # Générer une clé et un secret aléatoires pour Directus
    export KEY=\$(openssl rand -base64 32)
    export SECRET=\$(openssl rand -base64 32)

    echo 'Exécution de 'directus init' pour créer le projet...'
    directus init || exit_on_error \"Échec de l'initialisation du projet Directus.\"

    echo 'Exécution de 'directus bootstrap' pour configurer la base de données et l'administrateur...'
    directus bootstrap || exit_on_error \"Échec du bootstrap de Directus.\"

    echo 'Mise à jour/Création du fichier .env pour Directus...'
    cat <<EOF > \"$DIRECTUS_INSTALL_PATH/.env\"
DB_CLIENT=\"\$DB_CLIENT\"
DB_HOST=\"\$DB_HOST\"
DB_PORT=\"\$DB_PORT\"
DB_USER=\"\$DB_USER\"
DB_PASSWORD=\"\$DB_PASSWORD\"
DB_DATABASE=\"\$DB_DATABASE\"
ADMIN_EMAIL=\"\$ADMIN_EMAIL\"
ADMIN_PASSWORD=\"\$ADMIN_PASSWORD\"
KEY=\"\$KEY\"
SECRET=\"\$SECRET\"
PORT=$DIRECTUS_PORT
NODE_ENV=production
# URL_PUBLIC=http://\$NGINX_SERVER_NAME/directus # Sera géré par Nginx Reverse Proxy
EOF
    echo 'Fichier .env de Directus créé/mis à jour.'
" || exit_on_error "Échec de l'installation de Directus en tant que $DIRECTUS_RUN_USER."
check_status "L'installation de Directus a échoué." "Projet Directus créé et configuré."

echo "Autorisation du port Directus ($DIRECTUS_PORT) sur UFW..."
ufw allow "$DIRECTUS_PORT"/tcp || exit_on_error "Échec de l'autorisation du port Directus sur UFW."
check_status "L'autorisation du port Directus a échoué." "Port Directus autorisé sur UFW."

echo -e "\e[32mÉtape 5 terminée: Projet Directus créé et configuré.\e[0m"


# --- 6. Création d'un service Systemd pour Directus ---
echo -e "\n--- Étape 6: Création d'un service Systemd pour Directus ---"

DIRECTUS_SERVICE_FILE="/etc/systemd/system/directus.service"

echo "Création du fichier de service Systemd pour Directus: $DIRECTUS_SERVICE_FILE..."
cat <<EOL > "$DIRECTUS_SERVICE_FILE"
[Unit]
Description=Directus API
After=network.target mysql.service

[Service]
Type=simple
User=$DIRECTUS_RUN_USER
Group=$DIRECTUS_RUN_USER
WorkingDirectory=$DIRECTUS_INSTALL_PATH
EnvironmentFile=$DIRECTUS_INSTALL_PATH/.env
ExecStart=/usr/bin/npm run start # Assurez-vous que 'npm run start' est défini dans package.json de Directus
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=directus

[Install]
WantedBy=multi-user.target
EOL
check_status "La création du fichier de service Systemd a échoué." "Fichier de service Systemd Directus créé."

echo "Rechargement des configurations Systemd..."
systemctl daemon-reload || exit_on_error "Échec du rechargement des daemons Systemd."
check_status "Le rechargement des daemons Systemd a échoué." "Configurations Systemd rechargées."

echo "Activation du service Directus pour qu'il démarre automatiquement au boot..."
systemctl enable directus || exit_on_error "Échec de l'activation du service Directus."
check_status "L'activation du service Directus a échoué." "Service Directus activé au démarrage."

echo "Démarrage du service Directus..."
systemctl start directus || exit_on_error "Échec du démarrage du service Directus."
check_status "Le démarrage du service Directus a échoué." "Service Directus démarré."

echo "Vérification de l'état du service Directus (attendez quelques secondes)..."
sleep 10 # Laisser le temps au service de démarrer
systemctl status directus | grep "Active: active (running)" || exit_on_error "Le service Directus n'est pas en cours d'exécution."
check_status "Le service Directus n'est pas en cours d'exécution." "Service Directus en cours d'exécution."

echo -e "\e[32mÉtape 6 terminée: Service Directus créé et démarré.\e[0m"


# --- 7. Configuration Nginx en Reverse Proxy pour Directus (avec support multi-sites) ---
echo -e "\n--- Étape 7: Configuration Nginx en Reverse Proxy pour Directus ---"

NGINX_DIRECTUS_CONF_PATH="/etc/nginx/sites-available/$DIRECTUS_PROJECT_NAME"

echo "Création du fichier de configuration Nginx Reverse Proxy pour Directus..."
cat <<EOL > "$NGINX_DIRECTUS_CONF_PATH"
server {
    listen 80;
    listen [::]:80;

    server_name $NGINX_SERVER_NAME; # Accès via le nom d'hôte principal

    # Configuration pour le site par défaut (si d'autres sites sont hébergés)
    location / {
        # Si vous avez d'autres sites sur ce server_name, vous pouvez les gérer ici
        # Par exemple, pour servir des fichiers statiques pour un autre site, ou rediriger
        # Pour le moment, nous allons simplement rediriger vers le répertoire par défaut Nginx
        # try_files \$uri \$uri/ =404; # Ceci est pour un site statique
        # Si vous voulez Directus comme application par défaut à la racine, décommenter la section proxy_pass ci-dessous
        # proxy_pass http://localhost:$DIRECTUS_PORT;
        # proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # proxy_set_header Host \$host;
        # proxy_set_header X-Real-IP \$remote_addr;
        # proxy_buffering off;
        # proxy_request_buffering off;
        # proxy_http_version 1.1;
        # proxy_set_header Upgrade \$http_upgrade;
        # proxy_set_header Connection "upgrade";

        # Par défaut, ce bloc '/' sert le contenu de $NGINX_ROOT_DIR.
        # Pour Directus, nous allons le configurer sur un sous-chemin ou un sous-domaine.
        # Ici, nous le mettons sur un sous-chemin /directus
        root /var/www/$NGINX_SERVER_NAME; # Laisser le root pour le site par défaut
        index index.html index.htm index.nginx-debian.html;
    }

    # Configuration du reverse proxy pour Directus sur le chemin /directus
    location /directus {
        proxy_pass http://localhost:$DIRECTUS_PORT;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Si vous voulez Directus sur un sous-domaine (ex: directus.yourhostname.com), vous feriez un autre bloc server
    # server {
    #    listen 80;
    #    server_name directus.$NGINX_SERVER_NAME;
    #    location / {
    #        proxy_pass http://localhost:$DIRECTUS_PORT;
    #        # ... headers ...
    #    }
    # }
}
EOL
check_status "La création du fichier de configuration Nginx pour Directus a échoué." "Fichier de configuration Nginx pour Directus créé."

echo "Création d'un lien symbolique pour le site Directus..."
ln -sf "$NGINX_DIRECTUS_CONF_PATH" "/etc/nginx/sites-enabled/" || exit_on_error "Échec de la création du lien symbolique Nginx pour Directus."
check_status "La création du lien symbolique Nginx pour Directus a échoué." "Lien symbolique Nginx pour Directus créé."

echo "Vérification de la syntaxe de configuration Nginx..."
nginx -t || exit_on_error "Erreur de syntaxe dans la configuration Nginx."
check_status "La vérification de la syntaxe Nginx a échoué." "Syntaxe Nginx correcte."

echo "Redémarrage de Nginx pour appliquer les changements..."
systemctl restart nginx || exit_on_error "Échec du redémarrage de Nginx."
check_status "Le redémarrage de Nginx a échoué." "Nginx configuré en reverse proxy et redémarré."

echo -e "\e[32mÉtape 7 terminée: Nginx configuré en reverse proxy pour Directus.\e[0m"


# --- Remarque sur la 7ème remarque (Persistance de KEY et SECRET) ---
echo -e "\n--- Remarque 7: Gestion des clés Directus ---"
echo "Votre 7ème remarque concernait la persistance des clés KEY et SECRET de Directus."
echo "Actuellement, ces clés sont générées aléatoirement à chaque exécution du script"
echo "et sont stockées dans le fichier '.env' de votre projet Directus."
echo "Cela signifie que si vous réexécutez le script, de nouvelles clés seront générées,"
echo "ce qui invalidera les sessions utilisateur et les tokens d'authentification existants."
echo "Pour un environnement de production stable, cela n'est pas idéal."

echo "Solutions possibles pour la production (non implémentées automatiquement ici) :"
echo "1.  \e[1mGénération unique et persistance manuelle :\e[0m Générez les clés une seule fois,"
echo "    sauvegardez-les dans un endroit sûr (hors du serveur si possible, ou dans un gestionnaire de secrets),"
echo "    et configurez-les manuellement dans le fichier '.env' de Directus (ou via des variables d'environnement)."
echo "    Si vous devez réexécuter le script d'installation, assurez-vous de ne pas regénérer ces clés"
echo "    ou de reconfigurer les anciennes si elles sont importantes pour la persistance des sessions."
echo "2.  \e[1mVariables d'environnement du système :\e[0m Au lieu de les stocker dans le .env,"
echo "    vous pouvez les définir comme variables d'environnement au niveau du système"
echo "    (par exemple, dans `/etc/environment` ou via Systemd dans le service Directus)."
echo "    Ceci est plus sécurisé que de les laisser dans un fichier lisible par tous."
echo "3.  \e[1mGestionnaire de secrets :\e[0m Pour des déploiements plus complexes, utilisez des outils"
echo "    comme HashiCorp Vault ou Kubernetes Secrets pour gérer ces clés."
echo ""
echo "Pour ce script, la génération aléatoire et l'écriture dans .env restent pour la commodité"
echo "d'une première installation, mais soyez conscient de l'impact en cas de réexécution."
echo -e "\e[32mRemarque 7 traitée.\e[0m"


echo -e "\n\e[35m--------------------------------------------------------\e[0m"
echo -e "\e[35mInstallation et configuration complètes !\e[0m"
echo -e "\e[35m--------------------------------------------------------\e[0m"
echo "Récapitulatif :"
echo "  - Nginx est configuré pour servir le contenu depuis $NGINX_ROOT_DIR"
echo "  - Votre site web par défaut est accessible via HTTP sur http://$NGINX_SERVER_NAME/"
echo "  - Node.js 22 est installé."
echo "  - MySQL est installé, sécurisé via mysql_secure_installation automatisé,"
echo "    avec l'utilisateur '$MYSQL_USER' et la base de données '$MYSQL_DB_NAME'."
echo "  - Samba est configuré. Partage '$SAMBA_SHARE_NAME' sur '$SAMBA_SHARE_PATH'."
echo "    Accès via l'utilisateur système '$CALLING_USER'."
echo "  - Directus est installé à $DIRECTUS_INSTALL_PATH et s'exécute en tant que service."
echo "  - Le service Directus est démarré et s'exécutera automatiquement au boot,"
echo "    exécuté par l'utilisateur système '$DIRECTUS_RUN_USER'."
echo "  - Nginx est configuré en reverse proxy. Votre Directus est accessible via :"
echo "    \e[1mhttp://$NGINX_SERVER_NAME/directus\e[0m"
echo "  - Les identifiants Directus Admin sont: Email: $DIRECTUS_ADMIN_EMAIL, Mot de passe: $DIRECTUS_ADMIN_PASSWORD"
echo -e "\n\e[31mIMPORTANT: Changez IMMÉDIATEMENT les mots de passe par défaut pour MySQL et Directus en production !\e[0m"
echo "  Pour MySQL : mysql -u $MYSQL_USER -p"
echo "  Pour Directus : Connectez-vous à l'admin et modifiez le mot de passe."
echo "  Sécurisez également les permissions sur le fichier .env de Directus."
echo -e "\nPour vérifier l'état des services:"
echo "  sudo systemctl status nginx"
echo "  sudo systemctl status mysql"
echo "  sudo systemctl status directus"
echo "  sudo systemctl status smbd nmbd"
echo "  sudo ufw status verbose"
echo "Pour accéder au partage Samba depuis un client Windows: \\\\$NGINX_SERVER_NAME\\$SAMBA_SHARE_NAME"