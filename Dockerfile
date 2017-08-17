FROM resin/raspberrypi3-debian:latest
#FROM bingen/rpi-nginx-php5

ARG ZONEMINDER_DATA_PATH

RUN echo deb http://deb.debian.org/debian jessie-backports main contrib non-free >> /etc/apt/sources.list
RUN apt-get update && \
    apt-get install -y vim mariadb-client-10.0 apache2 && \
    apt-get install -y php5 php5-fpm php5-cgi php5-common php5-mcrypt php5-mysql php5-cli php5-gd php5-curl php-apc \
    zoneminder

# now add our hand-written nginx-default-configuration which makes use of all the stuff so far prepared
COPY default /etc/nginx/sites-available/default

# Create the data-directory where ZONEMINDER can store its stuff
#RUN mkdir -p "${ZONEMINDER_DATA_PATH}" && \
#    chown -R www-data:www-data "${ZONEMINDER_DATA_PATH}"

WORKDIR /
COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
COPY *.conf /etc/zm/

RUN chgrp -c www-data /etc/zm/zm.conf && \
    systemctl enable zoneminder.service && \
    cp /etc/zm/apache.conf /etc/apache2/conf-available/zoneminder.conf && \
    a2enconf zoneminder && \
    a2enmod cgi && \
    a2enmod rewrite

#VOLUME ${ZONEMINDER_DATA_PATH}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD service apache2 start && service zoneminder start && tail -f /dev/null