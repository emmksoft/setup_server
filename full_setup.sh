#!/bin/bash

# --- VARIABLES GLOBALES ---
NGINX_SERVER_NAME=$(hostname -f) # Utilise le nom d'hôte complet du serveur
NGINX_ROOT_DIR="/var/www/$NGINX_SERVER_NAME" # Racine du site Nginx (pour le site par défaut)
DIRECTUS_PROJECT_NAME="directus_mksoft"
DIRECTUS_INSTALL_PATH="/var/www/$DIRECTUS_PROJECT_NAME"
DIRECTUS_PORT=8055 # Port interne de Directus

# MySQL User & DB
MYSQL_DB_NAME="mksoft_db"
# MYSQL_ROOT_PASSWORD sera défini dynamiquement lors de l'étape 4
# MYSQL_USER et MYSQL_PASSWORD seront définis dynamiquement lors de l'étape 4

# Samba User & Share (sera demandé à l'utilisateur)
SAMBA_SHARE_NAME="shared_data"
SAMBA_SHARE_PATH="/srv/$SAMBA_SHARE_NAME" # Chemin du partage Samba (corrigé ici : utilisez SAMBA_SHARE_NAME, pas SAMBA_SHARE_PATH)

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

# --- EXPORTER LES FONCTIONS POUR LES SOUS-SHELLS ---
# Cela peut aider dans certains contextes, mais la redéfinition directe est plus sûre pour 'bash -c'
export -f exit_on_error
export -f check_status
export -f get_password


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

echo "Sécurisation de MySQL via requêtes SQL directes..."

# Demander le NOUVEAU mot de passe root fort à l'utilisateur
# Ce mot de passe sera utilisé pour définir le mot de passe root et pour les opérations suivantes
get_password "Veuillez définir un NOUVEAU mot de passe FORT pour l'utilisateur root de MySQL" MYSQL_ROOT_PASSWORD_NEW

# Tenter de se connecter à MySQL en tant que root.
# On essaie d'abord sans mot de passe (cas après une installation fraîche ou si auth_socket)
# puis avec le mot de passe temporaire si MySQL 8 l'a généré.
MYSQL_ROOT_LOGIN_COMMAND=""
MYSQL_ROOT_CONNECT_SUCCESS=false

# Test 1: Connexion sans mot de passe (pour les systèmes qui utilisent auth_socket ou pas de mot de passe initial)
if mysql -u root -e "SELECT 1;" &>/dev/null; then
    MYSQL_ROOT_LOGIN_COMMAND="mysql -u root"
    MYSQL_ROOT_CONNECT_SUCCESS=true
    echo "Connecté à MySQL en tant que root sans mot de passe initial."
else
    # Test 2: Rechercher un mot de passe temporaire dans les logs MySQL 8+
    MYSQL_TEMP_PASSWORD=$(sudo grep -E "A temporary password|password for user 'root'" /var/log/mysql/error.log | tail -n 1 | grep -oP "password for user 'root'@'localhost' is: \K.*")
    if [ -n "$MYSQL_TEMP_PASSWORD" ]; then
        # Tenter de se connecter avec le mot de passe temporaire
        if mysql -u root -p"$MYSQL_TEMP_PASSWORD" -e "SELECT 1;" &>/dev/null; then
            MYSQL_ROOT_LOGIN_COMMAND="mysql -u root -p\"$MYSQL_TEMP_PASSWORD\""
            MYSQL_ROOT_CONNECT_SUCCESS=true
            echo "Connecté à MySQL en tant que root avec le mot de passe temporaire."
        fi
    fi
fi

if [ "$MYSQL_ROOT_CONNECT_SUCCESS" == "false" ]; then
    echo "ERREUR: Impossible de se connecter à MySQL en tant que root avec les méthodes par défaut."
    echo "Veuillez vérifier manuellement le mot de passe root (ex: sudo grep -E 'temporary password|password for user 'root'' /var/log/mysql/error.log) "
    echo "ou essayez de vous connecter via 'sudo mysql' pour diagnostiquer le problème."
    exit_on_error "Impossible de procéder à la sécurisation MySQL."
fi

# Exécuter les requêtes de sécurisation en utilisant la commande de connexion déterminée
# Le mot de passe root temporaire (s'il existe) est utilisé pour la connexion initiale,
# puis il est changé par MYSQL_ROOT_PASSWORD_NEW.
eval "$MYSQL_ROOT_LOGIN_COMMAND" <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD_NEW';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

if [ $? -eq 0 ]; then
    echo "Configuration MySQL sécurisée terminée via requêtes SQL."
else
    exit_on_error "Erreur lors de la configuration sécurisée de MySQL via requêtes SQL. Veuillez vérifier manuellement."
fi

# Mettre à jour la variable globale MYSQL_ROOT_PASSWORD pour les opérations suivantes
MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD_NEW"


echo "Configuration de l'utilisateur et de la base de données MySQL pour Directus..."

get_password "Veuillez entrer le nom d'utilisateur MySQL à créer pour Directus" MYSQL_USER
get_password "Veuillez entrer le mot de passe pour l'utilisateur MySQL '$MYSQL_USER'" MYSQL_PASSWORD

# Créer l'utilisateur, la base de données et accorder les privilèges
# Utiliser le nouveau mot de passe root pour cette connexion
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB_NAME\`;
GRANT ALL PRIVILEGES ON \`$MYSQL_DB_NAME\`.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
" || exit_on_error "Échec de la création de l'utilisateur, de la base de données ou de l'octroi des privilèges MySQL."
check_status "La configuration de l'utilisateur/DB MySQL a échoué." "Utilisateur MySQL '$MYSQL_USER' et base de données '$MYSQL_DB_NAME' créés avec privilèges."

echo -e "\e[32mÉtape 4 terminée: MySQL installé et configuré.\e[0m"

# --- Installation et configuration de Samba ---
echo -e "\n--- Étape 5: Installation et configuration de Samba ---"
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

# --- 6. Création du projet Directus ---
echo -e "\n--- Étape 6: Création du projet Directus ---"

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
# Nous devons redéfinir les fonctions essentielles et passer les variables via ENV
sudo -u "<span class="math-inline">DIRECTUS\_RUN\_USER" bash \-c "
\# \-\-\- Redéfinir les fonctions dans ce sous\-shell \-\-\-
function exit\_on\_error \{
echo \-e \\"\\\\\\\\n\\\\\\\\e\[31mERREUR\: \\$1\\\\\\\\e\[0m\\" \# Texte rouge
exit 1
\}
function check\_status \{
if \[ \\</span>? -ne 0 ]; then
            exit_on_error \"\$1\"
        else
            echo -e \"\\\\e[32mOK: \$2\\\\e[0m\" # Texte vert
        fi
    }

    function get_password {
        local prompt_msg=\"\$1\"
        local password_var=\"\$2\"
        while true; do
            read -sp \"\$prompt_msg: \" entered_password
            echo
            if [[ -n \"\$entered_password\" ]]; then
                eval \"\$password_var='\$entered_password'\"
                break
            else
                echo -e \"\\\\e[31mLe mot de passe ne peut pas être vide. Veuillez réessayer.\\\\e[0m\"
            fi
        done
    }

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

    echo 'Vérification de l\'initialisation du projet Directus...'
    if [ ! -f \"\$DIRECTUS_INSTALL_PATH/.env\" ]; then
        echo 'Le fichier .env de Directus n\'existe pas. Initialisation du projet...'
        
        # Demander les emails/mots de passe de l'administrateur Directus
        # Ces variables sont ensuite utilisées pour définir les variables d'environnement pour Directus
        get_password \"Veuillez entrer l'email de l'administrateur Directus\" DIRECTUS_ADMIN_EMAIL_INNER
        get_password \"Veuillez entrer le mot de passe de l'administrateur Directus\" DIRECTUS_ADMIN_PASSWORD_INNER

        # Exporter les variables d'environnement nécessaires pour directus init et bootstrap
        export DB_CLIENT=\"mysql\"
        export DB_HOST=\"localhost\"
        export DB_PORT=\"3306\"
        export DB_USER=\"$MYSQL_USER\" # Propagé du shell parent
        export DB_PASSWORD=\"$MYSQL_PASSWORD\" # Propagé du shell parent
        export DB_DATABASE=\"<span class="math-inline">MYSQL\_DB\_NAME\\" \# Propagé du shell parent
export ADMIN\_EMAIL\=\\"\\$DIRECTUS\_ADMIN\_EMAIL\_INNER\\"
export ADMIN\_PASSWORD\=\\"\\$DIRECTUS\_ADMIN\_PASSWORD\_INNER\\"
\# Générer une clé et un secret aléatoires pour Directus
export KEY\=\\$\(openssl rand \-base64 32\)
export SECRET\=\\</span>(openssl rand -base64 32)

        echo 'Exécution de 'directus init' pour créer le projet...'
        # 'directus init' et 'directus bootstrap' liront les variables d'environnement exportées
        \$DIRECTUS_BIN init || exit_on_error \"Échec de l'initialisation du projet Directus.\"

        echo 'Exécution de 'directus bootstrap' pour configurer la base de données et l'administrateur...'
        \$DIRECTUS_BIN bootstrap || exit_on_error \"Échec du bootstrap de Directus.\"

        echo 'Création du fichier .env pour Directus...'
        # Utiliser printf pour construire le fichier .env de manière plus robuste
        # Les variables ici sont celles qui ont été exportées ci-dessus dans le sous-shell
        printf "DB_CLIENT=\"%s\"\\n" "\$DB_CLIENT" > \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_HOST=\"%s\"\\n" "\$DB_HOST" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_PORT=\"%s\"\\n" "\$DB_PORT" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_USER=\"%s\"\\n" "\$DB_USER" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_PASSWORD=\"%s\"\\n" "\$DB_PASSWORD" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "DB_DATABASE=\"%s\"\\n" "\$DB_DATABASE" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "ADMIN_EMAIL=\"%s\"\\n" "\$ADMIN_EMAIL" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "ADMIN_PASSWORD=\"%s\"\\n" "\$ADMIN_PASSWORD" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "KEY=\"%s\"\\n" "\$KEY" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "SECRET=\"%s\"\\n" "\$SECRET" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        printf "PORT=%s\\n" "$DIRECTUS_PORT" >> \"\$DIRECTUS_INSTALL_PATH/.env\" # Directus Port from parent shell
        printf "NODE_ENV=production\\n" >> \"\$DIRECTUS_INSTALL_PATH/.env\"
        # printf "URL_PUBLIC=http://%s/directus\\n" "$NGINX_SERVER_NAME" >> \"\$DIRECTUS_INSTALL_PATH/.env\" # Nginx Server Name from parent shell
        
        # S'assurer que le fichier .env a les bonnes permissions (lecture/écriture pour le propriétaire uniquement)
        chmod 600 \"\$DIRECTUS_INSTALL_PATH/.env\"

        echo 'Fichier .env de Directus créé.'
        check_status \"L'initialisation/bootstrap de Directus a échoué.\" \"Projet Directus initialisé et configuré.\"
    else
        echo 'Le fichier .env de Directus existe déjà. Le projet Directus semble déjà configuré.'
    fi
" || exit_on_error "Échec de l'installation/configuration de Directus en tant que $DIRECTUS_RUN_USER."
check_status "L'installation de Directus a échoué." "Projet Directus créé et configuré."

echo "Autorisation du port Directus ($DIRECTUS_PORT) sur UFW..."
if ! ufw status | grep -q "$DIRECTUS_PORT"; then
    ufw allow "$DIRECTUS_PORT"/tcp || exit_on_error "Échec de l'autorisation du port Directus sur UFW."
    check_status "L'autorisation du port Directus a échoué." "Port Directus autorisé sur UFW."
else
    echo "Règle pour le port Directus (<span class="math-inline">DIRECTUS\_PORT\) déjà présente dans UFW\."
fi
echo \-e "\\e\[32mÉtape 6 terminée\: Projet Directus créé et configuré\.\\e\[0m"
\# \-\-\- 7\. Création d'un service Systemd pour Directus \-\-\-
echo \-e "\\n\-\-\- Étape 7\: Création d'un service Systemd pour Directus \-\-\-"
DIRECTUS\_SERVICE\_FILE\="/etc/systemd/system/directus\.service"
echo "Vérification du fichier de service Systemd pour Directus\.\.\."
\# Vérifier si le service existe et si son contenu est conforme
CURRENT\_SERVICE\_HASH\=</span>(md5sum "$DIRECTUS_SERVICE_FILE" 2>/dev/null | awk '{print <span class="math-inline">1\}'\)
EXPECTED\_SERVICE\_CONTENT\=</span>(cat <<EOL
[Unit]
Description=Directus API
After=network.target mysql.service

[Service]
Type=simple
User=$DIRECTUS_RUN_USER
Group=$DIRECTUS_RUN_USER
WorkingDirectory=$DIRECTUS_INSTALL_PATH
EnvironmentFile=<span class="math-inline">DIRECTUS\_INSTALL\_PATH/\.env
ExecStart\=/usr/bin/npm run start \# Assurez\-vous que 'npm run start' est défini dans package\.json de Directus
Restart\=always
RestartSec\=10
StandardOutput\=syslog
StandardError\=syslog
SyslogIdentifier\=directus
\[Install\]
WantedBy\=multi\-user\.target
EOL
\)
EXPECTED\_SERVICE\_HASH\=</span>(echo "$EXPECTED_SERVICE_CONTENT" | md5sum | awk '{print $1}')

if [ ! -f "$DIRECTUS_SERVICE_FILE" ] || [ "$CURRENT_SERVICE_HASH" != "$EXPECTED_SERVICE_HASH" ]; then
    echo "Le fichier de service Systemd pour Directus n'existe pas ou son contenu est différent. Création/Mise à jour..."
    echo "$EXPECTED_SERVICE_CONTENT" > "$DIRECTUS_SERVICE_FILE" || exit_on_error "Échec de la création du fichier de service Systemd."
    check_status "La création du fichier de service Systemd a échoué." "Fichier de service Systemd Directus créé/mis à jour."
else
