#!/bin/bash

# Colores para mensajes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

# Función para recopilar todos los datos
collect_data() {
    # Datos de usuario
    while true; do
        read -p "Ingrese nombre de usuario: " username
        if id "$username" >/dev/null 2>&1; then
            echo -e "${YELLOW}El usuario $username ya existe${NC}"
            read -p "¿Desea continuar con este usuario? (s/n): " continue_user
            if [[ $continue_user =~ ^[Ss]$ ]]; then
                break
            fi
        else
            break
        fi
    done
    
    read -s -p "Ingrese contraseña para el usuario: " user_password
    echo

    # Datos del sitio web
    while true; do
        read -p "Ingrese el dominio: " domain
        if validate_domain "$domain"; then
            break
        else
            echo -e "${RED}Dominio inválido${NC}"
        fi
    done
    
    # Verificar si el dominio ya está configurado
    if [ -d "/var/www/$domain" ] || [ -f "/usr/local/lsws/conf/vhosts/$domain.xml" ]; then
        echo -e "${YELLOW}El dominio $domain ya está configurado${NC}"
        read -p "¿Desea eliminar la configuración existente? (s/n): " delete_existing
        if [[ $delete_existing =~ ^[Ss]$ ]]; then
            rm -rf "/var/www/$domain" 2>/dev/null
            rm -f "/usr/local/lsws/conf/vhosts/$domain.xml" 2>/dev/null
            echo -e "${GREEN}Configuración existente eliminada${NC}"
        fi
    fi

    # Datos de WordPress
    read -p "¿Desea instalar WordPress? (s/n): " install_wp
    if [[ $install_wp =~ ^[Ss]$ ]]; then
        # Verificar si WordPress ya está instalado
        if [ -f "/var/www/$domain/html/wp-config.php" ]; then
            echo -e "${YELLOW}WordPress ya está instalado en $domain${NC}"
            read -p "¿Desea eliminarlo y reinstalarlo? (s/n): " reinstall_wp
            if [[ $reinstall_wp =~ ^[Ss]$ ]]; then
                rm -rf "/var/www/$domain/html/"* 2>/dev/null
                echo -e "${GREEN}Instalación anterior de WordPress eliminada${NC}"
            else
                install_wp="n"
            fi
        fi
        
        if [[ $install_wp =~ ^[Ss]$ ]]; then
            # Datos de la base de datos
            read -p "Nombre para la base de datos: " dbname
            read -p "Usuario para la base de datos: " dbuser
            read -s -p "Contraseña para la base de datos: " dbpass
            echo
            
            # Verificar si la base de datos ya existe
            if mysql -e "USE $dbname" 2>/dev/null; then
                echo -e "${YELLOW}La base de datos $dbname ya existe${NC}"
                read -p "¿Desea eliminarla y crearla de nuevo? (s/n): " recreate_db
                if [[ $recreate_db =~ ^[Ss]$ ]]; then
                    mysql -e "DROP DATABASE $dbname" 2>/dev/null
                    echo -e "${GREEN}Base de datos anterior eliminada${NC}"
                fi
            fi
        fi
    fi
}

# Función para crear usuario
create_user() {
    # Si el usuario no existe, crearlo
    if ! id "$username" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$username"
        echo "$username:$user_password" | chpasswd
        echo -e "${GREEN}Usuario creado exitosamente${NC}"
    else
        echo -e "${YELLOW}Usando usuario existente: $username${NC}"
    fi
}

# Función para configurar virtual host
configure_vhost() {
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

    echo -e "${GREEN}Virtual host configurado exitosamente${NC}"
}

# Función para instalar WordPress
install_wordpress() {
    # Crear base de datos y usuario
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
    
    # Generar claves de seguridad
    KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    sed -i "/define('AUTH_KEY/d" wp-config.php
    sed -i "/define('SECURE_AUTH_KEY/d" wp-config.php
    sed -i "/define('LOGGED_IN_KEY/d" wp-config.php
    sed -i "/define('NONCE_KEY/d" wp-config.php
    sed -i "/define('AUTH_SALT/d" wp-config.php
    sed -i "/define('SECURE_AUTH_SALT/d" wp-config.php
    sed -i "/define('LOGGED_IN_SALT/d" wp-config.php
    sed -i "/define('NONCE_SALT/d" wp-config.php
    sed -i "/#@-/a $KEYS" wp-config.php
    
    # Establecer permisos
    chown -R www-data:www-data /var/www/$domain/html
    chmod -R 755 /var/www/$domain/html
    
    echo -e "${GREEN}WordPress instalado exitosamente${NC}"
}

# Función principal para ejecutar todas las tareas
run_all_tasks() {
    echo -e "${GREEN}Iniciando configuración completa...${NC}"
    
    # Crear usuario
    create_user
    
    # Configurar virtual host
    configure_vhost
    
    # Instalar WordPress si se solicitó
    if [[ $install_wp =~ ^[Ss]$ ]]; then
        install_wordpress
    fi
    
    echo -e "${GREEN}¡Configuración completada!${NC}"
    echo -e "Resumen de configuración:"
    echo -e "Usuario: ${YELLOW}$username${NC}"
    echo -e "Dominio: ${YELLOW}$domain${NC}"
    if [[ $install_wp =~ ^[Ss]$ ]]; then
        echo -e "WordPress instalado en: ${YELLOW}http://$domain/${NC}"
        echo -e "Base de datos: ${YELLOW}$dbname${NC}"
        echo -e "Usuario BD: ${YELLOW}$dbuser${NC}"
    fi
}

# Ejecutar flujo principal
echo -e "${GREEN}===== Asistente de configuración WPLS =====${NC}"
collect_data
run_all_tasks
exit 0
