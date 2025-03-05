#!/bin/bash

# Colores para mensajes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Función para verificar si un comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verificar si el script se ejecuta como root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Este script debe ejecutarse como root${NC}"
    exit 1
fi

# Verificar dependencias necesarias
if ! command_exists curl; then
    apt-get update && apt-get install -y curl
fi

# Función para validar dominio
validate_domain() {
    if [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Función para crear usuario
create_user() {
    local username password
    while true; do
        read -p "Ingrese nombre de usuario: " username
        if id "$username" >/dev/null 2>&1; then
            echo -e "${RED}El usuario ya existe${NC}"
        else
            break
        fi
    done
    
    read -s -p "Ingrese contraseña: " password
    echo
    useradd -m -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    echo -e "${GREEN}Usuario creado exitosamente${NC}"
}

# Función para configurar virtual host
configure_vhost() {
    local domain
    while true; do
        read -p "Ingrese el dominio: " domain
        if validate_domain "$domain"; then
            break
        else
            echo -e "${RED}Dominio inválido${NC}"
        fi
    done
    
    # Crear directorio para el sitio
    mkdir -p /var/www/$domain/html
    chown -R www-data:www-data /var/www/$domain

    # Crear virtual host para LiteSpeed
    cat > /usr/local/lsws/conf/vhosts/$domain.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<virtualHostConfig>
    <docRoot>\$VH_ROOT/html</docRoot>
    <index>
        <useServer>0</useServer>
        <indexFiles>index.php, index.html</indexFiles>
    </index>
    <scriptHandler>
        <add suffix="php" handler="lsphp"/>
    </scriptHandler>
</virtualHostConfig>
EOF

    echo -e "${GREEN}Virtual host configurado${NC}"
}

# Función para instalar WordPress
install_wordpress() {
    local domain dbname dbuser dbpass
    
    read -p "Ingrese el dominio para WordPress: " domain
    if [ ! -d "/var/www/$domain" ]; then
        echo -e "${RED}El dominio no existe${NC}"
        return 1
    fi
    
    # Crear base de datos y usuario
    read -p "Nombre para la base de datos: " dbname
    read -p "Usuario para la base de datos: " dbuser
    read -s -p "Contraseña para la base de datos: " dbpass
    echo
    
    mysql -e "CREATE DATABASE IF NOT EXISTS $dbname"
    mysql -e "CREATE USER IF NOT EXISTS '$dbuser'@'localhost' IDENTIFIED BY '$dbpass'"
    mysql -e "GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'"
    mysql -e "FLUSH PRIVILEGES"
    
    # Descargar y configurar WordPress
    cd /var/www/$domain/html
    wget https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    mv wordpress/* .
    rm -rf wordpress latest.tar.gz
    
    # Configurar wp-config.php
    cp wp-config-sample.php wp-config.php
    sed -i "s/database_name_here/$dbname/" wp-config.php
    sed -i "s/username_here/$dbuser/" wp-config.php
    sed -i "s/password_here/$dbpass/" wp-config.php
    
    # Establecer permisos
    chown -R www-data:www-data /var/www/$domain/html
    chmod -R 755 /var/www/$domain/html
    
    echo -e "${GREEN}WordPress instalado exitosamente${NC}"
}

# Menú principal
while true; do
    echo "
1. Crear nuevo usuario
2. Configurar nuevo sitio web
3. Instalar WordPress
4. Salir
"
    read -p "Seleccione una opción: " option
    
    case $option in
        1) create_user ;;
        2) configure_vhost ;;
        3) install_wordpress ;;
        4) exit 0 ;;
        *) echo -e "${RED}Opción inválida${NC}" ;;
    esac
done
