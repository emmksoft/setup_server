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

echo "Installation des outils nécessaires (curl, git, rsync, ufw, openssl, expect, dos2unix)..."
for pkg in curl git rsync ufw openssl expect dos2unix; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "$pkg n'est pas installé. Installation de $pkg..."
        apt install -y "$pkg" || exit_on_error "Échec de l'installation de $pkg."
    else
        echo "$pkg est déjà installé."
    fi
done
check_status "L'installation des outils a échoué." "Outils nécessaires vérifiés/installés."

# Activer UFW (Uncomplicated Firewall)
echo "Vérification et activation du pare-feu UFW..."
if ufw status | grep -q "inactive"; then
    ufw enable || exit_on_error "Échec de l'activation de UFW."
    check_status "L'activation d'UFW a échoué." "UFW activé."
else
    echo "UFW est déjà actif."
fi

# Autoriser SSH
echo "Autorisation du port SSH (22) sur UFW..."
if ! ufw status | grep -q "OpenSSH"; then
    ufw allow OpenSSH || exit_on_error "Échec de l'autorisation de SSH sur UFW."
    check_status "L'autorisation de SSH sur UFW a échoué." "Port SSH autorisé sur UFW."
else
    echo "Règle OpenSSH déjà présente dans UFW."
fi

echo -e "\e[32mÉtape 1 terminée: Configuration initiale du serveur.\e[0m"


# --- 2. Installation et configuration de Nginx ---
echo -e "\n--- Étape 2: Installation et configuration de Nginx ---"

echo "Vérification et installation de Nginx..."
if ! dpkg -s nginx &>/dev/null; then
    apt install -y nginx || exit_on_error "Échec de l'installation de Nginx."
    check_status "L'installation de Nginx a échoué." "Nginx installé."
else
    echo "Nginx est déjà installé."
fi

echo "Autorisation de Nginx sur UFW (HTTP et HTTPS)..."
if ! ufw status | grep -q "Nginx Full"; then
    ufw allow 'Nginx Full' || exit_on_error "Échec de l'autorisation de Nginx sur UFW."
    check_status "L'autorisation de Nginx sur UFW a échoué." "Nginx autorisé sur UFW."
else
    echo "Règle 'Nginx Full' déjà présente dans UFW."
fi

echo "Création du dossier racine du site Nginx par défaut: $NGINX_ROOT_DIR..."
mkdir -p "$NGINX_ROOT_DIR" || exit_on_error "Échec de la création du dossier $NGINX_ROOT_DIR."
# Assurer que l'utilisateur de Nginx peut lire le contenu
chown -R www-data:www-data "$NGINX_ROOT_DIR"
chmod -R 755 "$NGINX_ROOT_DIR"
check_status "La création du dossier Nginx a échoué." "Dossier Nginx créé et permissions ajustées."

echo "Configuration du fichier de configuration Nginx pour le serveur par défaut ($NGINX_SERVER_NAME)..."
NGINX_DEFAULT_CONF_PATH="/etc/nginx/sites-available/$NGINX_SERVER_NAME"
# Créer un hash pour vérifier si le contenu a changé
CURRENT_NGINX_CONF_HASH=$(md5sum "$NGINX_DEFAULT_CONF_PATH" 2>/dev/null | awk '{print $1}')
EXPECTED_NGINX_CONF_CONTENT=$(cat <<EOL
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
)
EXPECTED_NGINX_CONF_HASH=$(echo "$EXPECTED_NGINX_CONF_CONTENT" | md5sum | awk '{print $1}')

if [ ! -f "$NGINX_DEFAULT_CONF_PATH" ] || [ "$CURRENT_NGINX_CONF_HASH" != "$EXPECTED_NGINX_CONF_HASH" ]; then
    echo "$NGINX_DEFAULT_CONF_PATH n'existe pas ou son contenu est différent. Création/Mise à jour..."
    echo "$EXPECTED_NGINX_CONF_CONTENT" > "$NGINX_DEFAULT_CONF_PATH" || exit_on_error "Échec de la création du fichier de configuration Nginx."
    check_status "La création du fichier de configuration Nginx a échoué." "Fichier de configuration Nginx par défaut créé/mis à jour."
else
    echo "Fichier de configuration Nginx par défaut ($NGINX_DEFAULT_CONF_PATH) déjà correct."
fi


echo "Création d'un lien symbolique pour le site par défaut..."
if [ ! -L "/etc/nginx/sites-enabled/$NGINX_SERVER_NAME" ]; then
    ln -sf "$NGINX_DEFAULT_CONF_PATH" "/etc/nginx/sites-enabled/" || exit_on_error "Échec de la création du lien symbolique Nginx."
    check_status "La création du lien symbolique Nginx a échoué." "Lien symbolique Nginx créé."
else
    echo "Lien symbolique Nginx pour $NGINX_SERVER_NAME déjà présent."
fi

echo "Suppression du lien symbolique du site par défaut de Nginx (si existant)..."
if [ -L "/etc/nginx/sites-enabled/default" ]; then
    rm -f /etc/nginx/sites-enabled/default || check_status "La suppression du lien par défaut Nginx a échoué." "Lien par défaut Nginx supprimé."
else
    echo "Lien par défaut Nginx non trouvé ou déjà supprimé."
fi

echo "Vérification de la syntaxe de configuration Nginx et redémarrage..."
nginx -t || exit_on_error "Erreur de syntaxe dans la configuration Nginx."
systemctl restart nginx || exit_on_error "Échec du redémarrage de Nginx."
systemctl enable nginx || exit_on_error "Échec de l'activation de Nginx au démarrage."
check_status "La configuration/redémarrage de Nginx a échoué." "Nginx configuré et redémarré."

# Créer un fichier de test simple
if [ ! -f "$NGINX_ROOT_DIR/index.html" ]; then
    echo "<h1>Bienvenue sur $NGINX_SERVER_NAME!</h1>" > "$NGINX_ROOT_DIR/index.html"
    check_status "La création de la page d'accueil Nginx a échoué." "Page d'accueil Nginx test créée."
else
    echo "Fichier index.html par défaut déjà présent."
fi

echo -e "\e[32mÉtape 2 terminée: Nginx installé et configuré.\e[0m"


# --- 3. Installation et vérification de Node.js 22 ---
echo -e "\n--- Étape 3: Installation et vérification de Node.js 22 ---"

NODE_INSTALLED=false
NPM_INSTALLED=false

# Vérifier si Node.js est déjà installé
if command -v node &>/dev/null; then
    NODE_INSTALLED=true
    NODE_VERSION=$(node -v)
    echo "Node.js $NODE_VERSION est déjà installé."
else
    echo "Node.js n'est pas installé."
fi

# Vérifier si npm est déjà installé
if command -v npm &>/dev/null; then
    NPM_INSTALLED=true
    NPM_VERSION=$(npm -v)
    echo "npm $NPM_VERSION est déjà installé."
else
    echo "npm n'est pas installé."
fi

if [ "$NODE_INSTALLED" == false ] || [[ "$NODE_VERSION" != v22.* ]]; then
    echo "Node.js 22.x n'est pas installé ou n'est pas la bonne version. Ajout du dépôt NodeSource et installation/mise à jour..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - || exit_on_error "Échec de l'ajout du dépôt NodeSource."
    apt install -y nodejs || exit_on_error "Échec de l'installation/mise à jour de Node.js 22."
    check_status "L'installation/mise à jour de Node.js a échoué." "Node.js 22 installé/mis à jour."
else
    echo "Node.js 22.x est déjà la version correcte."
fi

# Mettre à jour npm globalement
echo "Mise à jour de npm globalement à la dernière version..."
npm install -g npm@latest || exit_on_error "Échec de la mise à jour de npm."
check_status "La mise à jour de npm a échoué." "npm mis à jour."

echo "Vérification finale des versions de Node.js et npm..."
node_version_final=$(node -v)
npm_version_final=$(npm -v)
echo "Node.js version: $node_version_final"
echo "NPM version: $npm_version_final"

if [[ "$node_version_final" != v22.* ]]; then
    exit_on_error "La version de Node.js installée n'est pas la 22.x."
fi
check_status "La vérification finale des versions Node.js/NPM a échoué." "Versions Node.js/NPM vérifiées."

echo -e "\e[32mÉtape 3 terminée: Node.js 22 et npm installés et vérifiés.\e[0m"


# --- 4. Installation et configuration de MySQL ---
echo -e "\n--- Étape 4: Installation et configuration de MySQL ---"

echo "Vérification et installation de MySQL Server..."
if ! dpkg -s mysql-server &>/dev/null; then
    apt install -y mysql-server || exit_on_error "Échec de l'installation de MySQL Server."
    check_status "L'installation de MySQL a échoué." "MySQL Server installé."
else
    echo "MySQL Server est déjà installé."
fi

echo "Activation et démarrage de MySQL..."
systemctl enable mysql || exit_on_error "Échec de l'activation de MySQL au démarrage."
systemctl start mysql || exit_on_error "Échec du démarrage de MySQL."
check_status "Le démarrage de MySQL a échoué." "MySQL Server démarré."

echo "Exécution de 'mysql_secure_installation' de manière automatisée..."

# Vérifier si expect est installé (déjà fait au début du script, mais pour la robustesse ici)
if ! command -v expect &> /dev/null
then
    echo "expect n'est pas installé. Installation en cours..."
    sudo apt install -y expect || exit_on_error "Échec de l'installation de expect."
fi

# Demander le mot de passe root MySQL si l'utilisateur ne l'a pas déjà défini
# Tester si le root MySQL a déjà un mot de passe
MYSQL_ROOT_HAS_PASSWORD=false
if mysql -u root -p"" -e "exit" 2>/dev/null; then
    echo "Connexion MySQL root sans mot de passe réussie, on suppose qu'il n'y a pas de mot de passe root initial."
    MYSQL_ROOT_PASSWORD="" # Laisser vide pour que expect gère l'invite initiale
else
    # Demander le mot de passe s'il est déjà défini
    echo "Il semble que l'utilisateur root MySQL ait déjà un mot de passe."
    get_password "Veuillez entrer le mot de passe actuel de l'utilisateur root MySQL (laissez vide si vous ne savez pas ou si c'est une première installation)" MYSQL_ROOT_PASSWORD
    MYSQL_ROOT_HAS_PASSWORD=true
fi

# Utilisation de expect pour automatiser mysql_secure_installation
sudo expect <<EOF
set timeout 10
spawn mysql_secure_installation

# Handle the initial password prompt (might be empty if new install or if a password was just set)
expect {
    "Enter current password for root (enter for none):" {
        send "$MYSQL_ROOT_PASSWORD\r"
        exp_continue
    }
    "Would you like to setup VALIDATE PASSWORD component?" {
        send "n\r" ; # No to VALIDATE PASSWORD component
        exp_continue
    }
    "Change the root password?" {
        if { "$MYSQL_ROOT_HAS_PASSWORD" == "true" } {
            send "n\r" ; # No, if it was just entered
        } else {
            send "y\r" ; # Yes, if it's a new install and needs setting
            expect "New password:"
            send "$MYSQL_ROOT_PASSWORD\r"
            expect "Re-enter new password:"
            send "$MYSQL_ROOT_PASSWORD\r"
            expect "Remove anonymous users?" # Continue after setting password
        }
        exp_continue
    }
    "Do you wish to continue with the password provided?" { # MySQL 8 prompt after password validation
        send "y\r"
        exp_continue
    }
    "Remove anonymous users?" {
        send "y\r"
        exp_continue
    }
    "Disallow root login remotely?" {
        send "y\r"
        exp_continue
    }
    "Remove test database and access to it?" {
        send "y\r"
        exp_continue
    }
    "Reload privilege tables now?" {
        send "y\r"
        exp_continue
    }
    eof {
        # End of file, script finished
    }
}
expect eof
EOF

if [ $? -eq 0 ]; then
    echo "Configuration MySQL sécurisée terminée."
else
    echo "Erreur lors de la configuration sécurisée de MySQL. Veuillez vérifier manuellement."
    exit_on_error "mysql_secure_installation a échoué."
fi
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
echo "Vérification et installation de Samba..."
if ! dpkg -s samba &>/dev/null; then
    apt install -y samba || exit_on_error "Échec de l'installation de Samba."
    check_status "L'installation de Samba a échoué." "Samba installé."
else
    echo "Samba est déjà installé."
fi

echo "Création du dossier de partage Samba: $SAMBA_SHARE_PATH..."
mkdir -p "$SAMBA_SHARE_PATH" || exit_on_error "Échec de la création du dossier de partage Samba."
chown -R "$CALLING_USER":"$CALLING_USER" "$SAMBA_SHARE_PATH" # L'utilisateur appelant sera propriétaire du partage
chmod -R 775 "$SAMBA_SHARE_PATH"
check_status "La création du dossier de partage Samba a échoué." "Dossier de partage Samba créé."

echo "Ajout de l'utilisateur '$CALLING_USER' à Samba..."
if ! pdbedit -L -u "$CALLING_USER" &>/dev/null; then # Vérifie si l'utilisateur Samba existe déjà
    get_password "Veuillez entrer le mot de passe pour l'utilisateur Samba '$CALLING_USER'" CALLING_USER_PASSWORD
    (echo "$CALLING_USER_PASSWORD"; echo "$CALLING_USER_PASSWORD") | smbpasswd -a "$CALLING_USER" || exit_on_error "Échec de l'ajout de l'utilisateur Samba."
    smbpasswd -e "$CALLING_USER" # Activer l'utilisateur Samba
    check_status "L'ajout de l'utilisateur Samba a échoué." "Utilisateur Samba ajouté."
else
    echo "L'utilisateur Samba '$CALLING_USER' existe déjà."
fi


echo "Configuration du fichier smb.conf..."
# Vérifier si le partage existe déjà dans smb.conf
if ! grep -q "\[$SAMBA_SHARE_NAME\]" /etc/samba/smb.conf; then
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
else
    echo "Le partage Samba '$SAMBA_SHARE_NAME' est déjà configuré dans smb.conf."
fi

echo "Redémarrage du service Samba..."
systemctl restart smbd nmbd || exit_on_error "Échec du redémarrage de Samba."
check_status "Le redémarrage de Samba a échoué." "Samba redémarré."

echo -e "\e[32mInstallation et configuration de Samba terminées.\e[0m"

# ... (Partie du script avant l'étape 5) ...

# --- EXPORTER LES FONCTIONS POUR LES SOUS-SHELLS ---
# Ceci est CRUCIAL pour que les fonctions soient accessibles dans le 'sudo -u ... bash -c'
export -f exit_on_error
export -f check_status
export -f get_password

# ... (Le reste du script après l'étape 5, avant la section Directus) ...

# --- 5. Création du projet Directus ---
echo -e "\n--- Étape 5: Création du projet Directus ---"

echo "Création du dossier d'installation Directus: $DIRECTUS_INSTALL_PATH..."
if [ ! -d "$DIRECTUS_INSTALL_PATH" ]; then
    mkdir -p "$DIRECTUS_INSTALL_PATH" || exit_on_error "Échec de la création du dossier Directus."
    check_status "La création du dossier Directus a échoué." "Dossier Directus créé."
else
    echo "Le dossier d'installation Directus ($DIRECTUS_INSTALL_PATH) existe déjà."
fi
chown -R "$DIRECTUS_RUN_USER":"$DIRECTUS_RUN_USER" "$DIRECTUS_INSTALL_PATH"
chmod -R 755 "$DIRECTUS_INSTALL_PATH"

# Exécuter les commandes npm/directus en tant que DIRECTUS_RUN_USER
# IMPORTANT : On passe toutes les variables nécessaires au sous-shell via la commande export
sudo -u "$DIRECTUS_RUN_USER" bash -c "
    # Redéfinir les chemins des fonctions à l'intérieur du sous-shell si nécessaire
    # (Bien que export -f devrait suffire, cela peut parfois être plus robuste)
    # Laissez ces lignes commentées à moins que vous ne rencontriez encore des problèmes
    # exit_on_error() { /usr/bin/bash -c \"$(declare -f exit_on_error); exit_on_error \\\"\$@\\\"\"; }
    # check_status() { /usr/bin/bash -c \"$(declare -f check_status); check_status \\\"\$@\\\"\"; }
    # get_password() { /usr/bin/bash -c \"$(declare -f get_password); get_password \\\"\$@\\\"\"; }

    echo 'Déplacement vers le dossier Directus...'
    cd \"$DIRECTUS_INSTALL_PATH\" || exit_on_error \"Échec du déplacement vers le dossier Directus.\"

    echo 'Installation de Directus CLI localement...'
    # Installer Directus CLI localement (au lieu de globalement) pour le projet
    npm install directus@latest || exit_on_error \"Échec de l'installation de Directus CLI localement.\"
    check_status \"L'installation de Directus CLI localement a échoué.\" \"Directus CLI localement installé.\"

    # Chemin vers l'exécutable directus local
    DIRECTUS_BIN=\"./node_modules/.bin/directus\"

    if [ ! -f \"\$DIRECTUS_BIN\" ]; then
        exit_on_error \"L'exécutable Directus CLI n'a pas été trouvé à \$DIRECTUS_BIN.\"
    fi

    echo 'Vérification de l'initialisation du projet Directus...'
    if [ ! -f \"$DIRECTUS_INSTALL_PATH/.env\" ]; then
        echo 'Le fichier .env de Directus n'existe pas. Initialisation du projet...'
        # Les variables ADMIN_EMAIL et ADMIN_PASSWORD doivent être passées du shell parent
        # ou demandées directement ici si elles n'ont pas été passées.
        # Pour simplifier, on les demande directement ici car elles sont interactives.
        # Note: on ne peut pas utiliser get_password directement ici si elle n'est pas exportée/définie.
        # Puisqu'on l'a exportée, cela devrait fonctionner.
        get_password \"Veuillez entrer l'email de l'administrateur Directus\" DIRECTUS_ADMIN_EMAIL_INNER
        get_password \"Veuillez entrer le mot de passe de l'administrateur Directus\" DIRECTUS_ADMIN_PASSWORD_INNER

        # Configuration des variables d'environnement pour l'installation Directus
        export DB_CLIENT=\"mysql\"
        export DB_HOST=\"localhost\"
        export DB_PORT=\"3306\"
        export DB_USER=\"$MYSQL_USER\" # Ces variables sont exportées du shell parent
        export DB_PASSWORD=\"$MYSQL_PASSWORD\" # et donc disponibles ici
        export DB_DATABASE=\"$MYSQL_DB_NAME\"
        export ADMIN_EMAIL=\"\$DIRECTUS_ADMIN_EMAIL_INNER\"
        export ADMIN_PASSWORD=\"\$DIRECTUS_ADMIN_PASSWORD_INNER\"

        # Générer une clé et un secret aléatoires pour Directus
        export KEY=\$(openssl rand -base64 32)
        export SECRET=\$(openssl rand -base64 32)

        echo 'Exécution de 'directus init' pour créer le projet...'
        \$DIRECTUS_BIN init || exit_on_error \"Échec de l'initialisation du projet Directus.\"

        echo 'Exécution de 'directus bootstrap' pour configurer la base de données et l'administrateur...'
        \$DIRECTUS_BIN bootstrap || exit_on_error \"Échec du bootstrap de Directus.\"

        echo 'Création du fichier .env pour Directus...'
        # Utiliser printf pour construire le fichier .env de manière plus robuste
        printf "DB_CLIENT=\"%s\"\n" "\$DB_CLIENT" > \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_HOST=\"%s\"\n" "\$DB_HOST" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_PORT=\"%s\"\n" "\$DB_PORT" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_USER=\"%s\"\n" "\$DB_USER" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_PASSWORD=\"%s\"\n" "\$DB_PASSWORD" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_DATABASE=\"%s\"\n" "\$DB_DATABASE" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "ADMIN_EMAIL=\"%s\"\n" "\$ADMIN_EMAIL" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "ADMIN_PASSWORD=\"%s\"\n" "\$ADMIN_PASSWORD" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "KEY=\"%s\"\n" "\$KEY" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "SECRET=\"%s\"\n" "\$SECRET" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "PORT=%s\n" "$DIRECTUS_PORT" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        printf "NODE_ENV=production\n" >> \"$DIRECTUS_INSTALL_PATH/.env\"
        # printf "URL_PUBLIC=http://%s/directus\n" "\$NGINX_SERVER_NAME" >> \"$DIRECTUS_INSTALL_PATH/.env\" # Commenté comme dans votre script

        echo 'Fichier .env de Directus créé.'
        check_status \"L'initialisation/bootstrap de Directus a échoué.\" \"Projet Directus initialisé et configuré.\"
    else
        echo 'Le fichier .env de Directus existe déjà. Le projet Directus semble déjà configuré.'
    fi
" || exit_on_error "Échec de l'installation/configuration de Directus en tant que $DIRECTUS_RUN_USER."
check_status "L'installation de Directus a échoué." "Projet Directus créé et configuré."

# ... (Reste du script) ...

echo "Autorisation du port Directus ($DIRECTUS_PORT) sur UFW..."
if ! ufw status | grep -q "$DIRECTUS_PORT"; then
    ufw allow "$DIRECTUS_PORT"/tcp || exit_on_error "Échec de l'autorisation du port Directus sur UFW."
    check_status "L'autorisation du port Directus a échoué." "Port Directus autorisé sur UFW."
else
    echo "Règle pour le port Directus ($DIRECTUS_PORT) déjà présente dans UFW."
fi

echo -e "\e[32mÉtape 5 terminée: Projet Directus créé et configuré.\e[0m"


# --- 6. Création d'un service Systemd pour Directus ---
echo -e "\n--- Étape 6: Création d'un service Systemd pour Directus ---"

DIRECTUS_SERVICE_FILE="/etc/systemd/system/directus.service"

echo "Vérification du fichier de service Systemd pour Directus..."
# Vérifier si le service existe et si son contenu est conforme
CURRENT_SERVICE_HASH=$(md5sum "$DIRECTUS_SERVICE_FILE" 2>/dev/null | awk '{print $1}')
EXPECTED_SERVICE_CONTENT=$(cat <<EOL
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
)
EXPECTED_SERVICE_HASH=$(echo "$EXPECTED_SERVICE_CONTENT" | md5sum | awk '{print $1}')

if [ ! -f "$DIRECTUS_SERVICE_FILE" ] || [ "$CURRENT_SERVICE_HASH" != "$EXPECTED_SERVICE_HASH" ]; then
    echo "Le fichier de service Systemd pour Directus n'existe pas ou son contenu est différent. Création/Mise à jour..."
    echo "$EXPECTED_SERVICE_CONTENT" > "$DIRECTUS_SERVICE_FILE" || exit_on_error "Échec de la création du fichier de service Systemd."
    check_status "La création du fichier de service Systemd a échoué." "Fichier de service Systemd Directus créé/mis à jour."
else
    echo "Fichier de service Systemd Directus ($DIRECTUS_SERVICE_FILE) déjà correct."
fi

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
if ! systemctl status directus | grep -q "Active: active (running)"; then
    exit_on_error "Le service Directus n'est pas en cours d'exécution."
fi
check_status "Le service Directus n'est pas en cours d'exécution." "Service Directus en cours d'exécution."

echo -e "\e[32mÉtape 6 terminée: Service Directus créé et démarré.\e[0m"


# --- 7. Configuration Nginx en Reverse Proxy pour Directus (avec support multi-sites) ---
echo -e "\n--- Étape 7: Configuration Nginx en Reverse Proxy pour Directus ---"

NGINX_DIRECTUS_CONF_PATH="/etc/nginx/sites-available/$DIRECTUS_PROJECT_NAME"

echo "Vérification du fichier de configuration Nginx Reverse Proxy pour Directus..."
# Vérifier si le fichier existe et si son contenu est conforme
CURRENT_DIRECTUS_NGINX_HASH=$(md5sum "$NGINX_DIRECTUS_CONF_PATH" 2>/dev/null | awk '{print $1}')
EXPECTED_DIRECTUS_NGINX_CONTENT=$(cat <<EOL
server {
    listen 80;
    listen [::]:80;

    server_name $NGINX_SERVER_NAME; # Accès via le nom d'hôte principal

    # Configuration pour le site par défaut (si d'autres sites sont hébergés)
    location / {
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
}
EOL
)
EXPECTED_DIRECTUS_NGINX_HASH=$(echo "$EXPECTED_DIRECTUS_NGINX_CONTENT" | md5sum | awk '{print $1}')

if [ ! -f "$NGINX_DIRECTUS_CONF_PATH" ] || [ "$CURRENT_DIRECTUS_NGINX_HASH" != "$EXPECTED_DIRECTUS_NGINX_HASH" ]; then
    echo "Le fichier de configuration Nginx pour Directus n'existe pas ou son contenu est différent. Création/Mise à jour..."
    echo "$EXPECTED_DIRECTUS_NGINX_CONTENT" > "$NGINX_DIRECTUS_CONF_PATH" || exit_on_error "Échec de la création du fichier de configuration Nginx pour Directus."
    check_status "La création du fichier de configuration Nginx pour Directus a échoué." "Fichier de configuration Nginx pour Directus créé/mis à jour."
else
    echo "Fichier de configuration Nginx pour Directus ($NGINX_DIRECTUS_CONF_PATH) déjà correct."
fi

echo "Création d'un lien symbolique pour le site Directus..."
if [ ! -L "/etc/nginx/sites-enabled/$DIRECTUS_PROJECT_NAME" ]; then
    ln -sf "$NGINX_DIRECTUS_CONF_PATH" "/etc/nginx/sites-enabled/" || exit_on_error "Échec de la création du lien symbolique Nginx pour Directus."
    check_status "La création du lien symbolique Nginx pour Directus a échoué." "Lien symbolique Nginx pour Directus créé."
else
    echo "Lien symbolique Nginx pour Directus déjà présent."
fi

echo "Vérification de la syntaxe de configuration Nginx et redémarrage..."
nginx -t || exit_on_error "Erreur de syntaxe dans la configuration Nginx."
systemctl restart nginx || exit_on_error "Échec du redémarrage de Nginx."
check_status "La configuration/redémarrage de Nginx a échoué." "Nginx configuré en reverse proxy et redémarré."

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
echo "    (par exemple, dans \`/etc/environment\` ou via Systemd dans le service Directus)."
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
echo "  - Directus est installé localement à $DIRECTUS_INSTALL_PATH et s'exécute en tant que service."
echo "  - Le service Directus est démarré et s'exécutera automatiquement au boot,"
echo "    exécuté par l'utilisateur système '$DIRECTUS_RUN_USER'."
echo "  - Nginx est configuré en reverse proxy. Votre Directus est accessible via :"
echo "    \e[1mhttp://$NGINX_SERVER_NAME/directus\e[0m"
echo "  - Les identifiants Directus Admin sont: Email: \$DIRECTUS_ADMIN_EMAIL_INNER (demandé pendant l'installation), Mot de passe: \$DIRECTUS_ADMIN_PASSWORD_INNER (demandé pendant l'installation)"
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
