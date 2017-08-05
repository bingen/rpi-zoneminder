#!/bin/bash

#set -e

#ZONEMINDER_DB_PWD=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo;`
ZONEMINDER_DB_PWD=`openssl rand -base64 20`
# It's hardcoded in /usr/share/zoneminder/db/zm_create.sql
ZONEMINDER_DB_NAME=zm
#TODO!!
ZONEMINDER_DATA_PATH=TODO

if [ -z "$ZONEMINDER_SERVER_NAME" ]; then
    echo >&2 'error: you have to provide a server-name'
    echo >&2 '  Did you forget to add -e HOSTNAME=... ?'
    exit 1
fi

sudo sed -i "s/server_name localhost/server_name $ZONEMINDER_SERVER_NAME/g" /etc/nginx/sites-available/default

# set Admin password from secret
if [ ! -z $ZONEMINDER_ADMIN_PWD_FILE -a -f $ZONEMINDER_ADMIN_PWD_FILE ]; then
    ZONEMINDER_ADMIN_PWD=`cat $ZONEMINDER_ADMIN_PWD_FILE`;
fi
# set DB root password from secret
if [ ! -z $MYSQL_ROOT_PWD_FILE -a -f $MYSQL_ROOT_PWD_FILE ]; then
    MYSQL_ROOT_PWD=`cat $MYSQL_ROOT_PWD_FILE`;
fi

# check needed variables
if [[ -z ${DB_HOST} || -z ${ZONEMINDER_DB_NAME} || -z ${ZONEMINDER_DB_USER} \
            || -z ${ZONEMINDER_DB_PWD} || -z ${ZONEMINDER_ADMIN_PWD} \
            || -z ${ZONEMINDER_DATA_PATH} ]]; then
    echo "Missing variable! You must provide: DB_HOST, ZONEMINDER_DB_NAME, \
ZONEMINDER_DB_USER, ZONEMINDER_DB_PWD, ZONEMINDER_ADMIN_PWD, ZONEMINDER_DATA_PATH";
    env;
    exit 1;
fi

# SSL certificates
if [ ! -f /etc/nginx/ssl/zoneminder.crt ]; then
    sudo mkdir /etc/nginx/ssl
    sudo openssl genrsa -out /etc/nginx/ssl/zoneminder.key 4096
    sudo openssl req -new -sha256 -batch -subj "/CN=$ZONEMINDER_SERVER_NAME" -key /etc/nginx/ssl/zoneminder.key -out /etc/nginx/ssl/zoneminder.csr
    sudo openssl x509 -req -sha256 -days 3650 -in /etc/nginx/ssl/zoneminder.csr -signkey /etc/nginx/ssl/zoneminder.key -out /etc/nginx/ssl/zoneminder.crt
fi

# Config file
CONFIG_FILE=/etc/zm/zm.conf
#sed -i 's/ZM_PATH_DATA=.*/ZM_PATH_DATA=${ZONEMINDER_DATA_PATH}/' ${CONFIG_FILE}
sed -i 's/ZM_DB_HOST=.*/ZM_DB_HOST=${DB_HOST}/' ${CONFIG_FILE}
sed -i 's/ZM_DB_USER=.*/ZM_DB_USER=${ZONEMINDER_DB_USER}/' ${CONFIG_FILE}
sed -i 's/ZM_DB_PASS=.*/ZM_DB_USER=${ZONEMINDER_DB_PWD}/' ${CONFIG_FILE}
# It's hardcoded in /usr/share/zoneminder/db/zm_create.sql:
#sed -i 's/ZM_DB_NAME=.*/ZM_DB_USER=${ZONEMINDER_DB_NAME}/' ${CONFIG_FILE}

function check_result {
    if [ $1 != 0 ]; then
        echo "Error: $2";
        exit 1;
    fi
}

# ### DB ###

# wait for DB to be ready
R=111
while [ $R -eq 111 ]; do
    mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "SHOW DATABASES"  2> /dev/null;
    R=$?;
done

# check if DB exists (not needed actually, but good to log it)
DB_EXISTS=$(mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "SHOW DATABASES" 2> /dev/null | grep ${ZONEMINDER_DB_NAME})
echo DB exists: ${DB_EXISTS}
#if [ ! -z "${DB_EXISTS}" ]; then
#fi

echo Creating Database and User
mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "DROP DATABASE IF EXISTS ${ZONEMINDER_DB_NAME};"
check_result $? "Dropping DB"
cat /usr/share/zoneminder/db/zm_create.sql | sudo mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST}

# 'IF EXISTS' for DROP USER is available from MariaDB 10.1.3 only
mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "DROP USER ${ZONEMINDER_DB_USER};" || echo "It seems it didn't exist"
mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "CREATE USER ${ZONEMINDER_DB_USER} IDENTIFIED BY '${ZONEMINDER_DB_PWD}';"
check_result $? "Creating User"

echo 'GRANT LOCK TABLES,ALTER,CREATE,SELECT,INSERT,UPDATE,DELETE,INDEX ON zm.* to 'zmuser'@localhost identified by "${ZONEMINDER_DB_PWD}";'    | sudo mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} mysql
check_result $? "Granting permissions"

mysql -u root -p${MYSQL_ROOT_PWD} -h ${DB_HOST} -e "FLUSH PRIVILEGES;"
check_result $? "Flushing privileges"

unset MYSQL_ROOT_PWD

# Configure

mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Config SET Value="1" WHERE Name = "ZM_OPT_USE_AUTH";'
mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Config SET Value="builtin" WHERE Name = "ZM_AUTH_TYPE";'
mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Config SET Value="hashed" WHERE Name = "ZM_AUTH_RELAY";'
mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Config SET Value="flat" WHERE Name = "ZM_CSS_DEFAULT";'
mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Config SET Value="classic" WHERE Name = "ZM_SKIN_DEFAULT";'

#Admin pwd
mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
      'UPDATE Users SET Password="${ZONEMINDER_ADMIN_PWD}" WHERE Username = "admin";'
#Monitors
for monitor in `ls /etc/zm/*.conf`; do
    . ${monitor}
    mysql -u ${ZONEMINDER_DB_USER} -p${ZONEMINDER_DB_PWD} -h ${DB_HOST} ${ZONEMINDER_DB_NAME} -e \
          'INSERT INTO Monitor (Name, Type, Function, Enabled, Protocol, Method, Ip, Port, Path, Subpath, Options, User, Pass, Width, Height, Colours, MaxFPS, AlarmMaxFPS) VALUES ("${NAME}", "${TYPE}", "${FUNCTION}", "${ENABLED}", "${PROTOCOL}", "${METHOD}", "${IP}", "${PORT}", "${PATH}", "${SUBPATH}", "${OPTIONS}", "${USER}", "${PASS}", "${WIDTH}", "${HEIGHT}", "${COLOURS}", "${MAXFPS}", "${ALARMMAXFPS);'
done;

exec "$@"
