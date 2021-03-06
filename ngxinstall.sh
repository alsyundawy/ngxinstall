#!/bin/sh
# vim: set expandtab sw=4 ts=4 sts=4:
#
# Simple shell script to install nginx with Wordpress, user jailed using chroot 
# setup to improve security. Send bug report to asfik@svrpnr.net.

# define log path
log=/root/ngxinstall.log

# define color code
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
normal=$(tput sgr0)
bold=$(tput bold)

# functions to format text
prntinfo () {
    message=$1
    printf "${cyan}▣ ${normal}${message}..."
}

prntok () {
    printf "${green}${bold}done ✔${normal}\n"
}

prntwarn () {
    message=$1
    printf "${yellow}${bold}[⚠ warn] $message.${normal}\n\n"
}

prnterr () {
    message=$1
    printf "${red}${bold}[⛔ error] $message.${normal}\n\n"
    exit 1
}

# check if the script run as root
curruid=$(id -u)
if [ "${curruid}" -ne 0 ]; then
    prnterr "please switch to root account"
fi

# check CentOS version
if [ -f /etc/centos-release ]; then
    centver=$(awk -F'release ' '{print $2}' /etc/centos-release | cut -d "." -f1)
    if [ "${centver}" -ne 7 ]; then
        prnterr "sorry this script only work on CentOS 7"
    fi
else
    prnterr "sorry this script only work on CentOS 7"
fi

# print general usage
usage () {
    echo
    printf "Usage: ${cyan}./ngxinstall.sh ${normal}--domainname ${green}<domainname> ${normal} --username ${green}<username> ${normal}--email ${green}<email>${normal}\n"
    echo 
}

# check command line arguments number
if [[ $# -eq 0 || $# -lt 6 ]];then
    usage
    exit 1
fi

# capture the variables from arguments
while [ "$1" != "" ]; do
    case $1 in
        --help)
            usage
            exit 0
            ;;
        --domainname)
            shift
            domainname=$1
            shift
            ;;
        --username)
            shift
            username=$1
            shift
            ;;
        --email)
            shift
            email=$1
            shift
            ;;
        *)
            printf "Unrecognized option: $1\n\n"
            usage
            exit 1
            ;;
    esac
done

# check if the username exist
getent passwd ${username} > /dev/null 2&>1
retval=$?

if [ "${retval}" -eq 0 ]; then
    prnterr "username ${username} exist"
fi

# just another counter :)
timestart=$(date +%s)

# disable selinux
if [ -x /sbin/setenforce ]; then
    /sbin/setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
fi

# whitelist port 80 and 443 if firewalld enabled
if [ -x /usr/bin/firewall-cmd ]; then
    fwstatus=$(systemctl is-active firewalld)
    if [ "${fwstatus}" == "active" ]; then
        firewall-cmd --zone=public --add-service=http > /dev/null 2>&1
        firewall-cmd --zone=public --add-service=https > /dev/null 2>&1
        firewall-cmd --zone=public --permanent --add-service=http > /dev/null 2>&1
        firewall-cmd --zone=public --permanent --add-service=https > /dev/null 2>&1
    fi
fi

# install necessary packages and additional repositories
echo
prntinfo "installing EPEL repo" 
yum -y install epel-release > $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "can't install EPEL repo"
fi

prntok

# for some reason Remi return non zero exit value if installed, so we need to check 
rpm --quiet -q remi-release
retval=$?

if [ "${retval}" -ne 0 ]; then
    prntinfo "installing Remi repo" 
    yum -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm >> $log 2>&1
    retval=$?

    if [ "${retval}" -ne 0 ]; then
        prnterr "can't install remi repo"
    fi

    prntok
fi

prntinfo "installing packages" 
yum -y install git wget vim-enhanced curl yum-utils gcc make unzip lsof telnet bind-utils shadow-utils sudo >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "can't install additional packages"
fi

prntok

# install Postfix
prntinfo "installing Postfix"
# remove installed sendmail binary, sorry Eric :)
rpm -e --nodeps sendmail sendmail-cf >> $log 2>&1
yum -y install postfix >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "can't install postfix"
fi

systemctl enable postfix >> $log 2>&1
systemctl start postfix >> $log 2>&1

psfxstts=$(systemctl is-active postfix)

if [ "${psfxstts}" != "active" ]; then
    systemctl status postfix>> $log 2>&1
    prnterr "failed to start postfix"
fi

prntok

# download config files from git repository
prntinfo "cloning files from git"
cd /tmp 
rm -rf ngxinstall
git clone https://github.com/asfihani/ngxinstall.git >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "unable to copy files from git"
fi

prntok

# setup jailkit and account
prntinfo "installing jailkit"
cd /tmp
rm -rf jailkit*
wget http://olivier.sessink.nl/jailkit/jailkit-2.19.tar.gz  >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "unable to download jailkit from https://olivier.sessink.nl/jailkit"
fi

if [ -f "jailkit-2.19.tar.gz" ]; then
    tar -xzvf jailkit-2.19.tar.gz  >> $log 2>&1
    cd jailkit-2.19 >> $log
    ./configure  >> $log 2>&1
    make >> $log 2>&1
    make install >> $log 2>&1
    cat /tmp/ngxinstall/config/jk_init.ini >> /etc/jailkit/jk_init.ini

    prntok
fi

# setup chroot for account
prntinfo "configuring account"
mkdir /chroot >> $log 2>&1
password=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")
adduser ${username}
echo "${username}:${password}" | chpasswd
mkdir -p /chroot/${username}

if [ -d "/chroot/${username}" ]; then
    jk_init -j /chroot/${username} basicshell editors extendedshell netutils ssh sftp scp basicid >> $log 2>&1
    jk_jailuser -s /bin/bash -m -j /chroot/${username} ${username} >> $log 2>&1
    
    mkdir -p /chroot/${username}/home/${username}/{public_html,logs}
    echo '<?php phpinfo(); ?>' > /chroot/${username}/home/${username}/public_html/info.php 
    chown -R ${username}: /chroot/${username}/home/${username}/{public_html,logs}
    chmod 755  /chroot/${username}/home/${username} /chroot/${username}/home/${username}/{public_html,logs}

    prntok
else
    prnterr "can't configure jailkit"
fi

# install nginx
prntinfo "installing nginx"
cp -p /tmp/ngxinstall/config/nginx.repo /etc/yum.repos.d/nginx.repo
yum -y install nginx >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "unable to install nginx"
fi

prntok

# configure nginx
prntinfo "configuring nginx"
mv /etc/nginx/nginx.conf{,.orig}
cp -p /tmp/ngxinstall/config/nginx.conf /etc/nginx/nginx.conf
mkdir -p /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ >> $log 2>&1
cp -p /tmp/ngxinstall/config/vhost.tpl /etc/nginx/sites-enabled/${domainname}.conf

sed -i "s/%%domainname%%/${domainname}/g" /etc/nginx/sites-enabled/${domainname}.conf
sed -i "s/%%username%%/${username}/g" /etc/nginx/sites-enabled/${domainname}.conf

cp -p /tmp/ngxinstall/config/wordpress.tpl /etc/nginx/conf.d/wordpress.conf
cp -p /tmp/ngxinstall/config/wp_super_cache.tpl /etc/nginx/conf.d/wp_super_cache.conf 

openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 4096 >> $log 2>&1

# disable apache if installed
rpm -q --quiet httpd
retval=$?

if [ "${retval}" -ne 0 ]; then
    systemctl stop httpd >> $log 2>&1
    systemctl disable httpd >> $log 2>&1
fi

# start nginx
systemctl enable nginx >> $log 2>&1
systemctl start nginx >> $log 2>&1

ngxstts=$(systemctl is-active nginx)

if [ "${ngxstts}" == "active" ]; then
    prntok
else
    systemctl status nginx >> $log 2>&1
    prnterr "failed to start nginx"
fi

# installing php 7.2
prntinfo "installing PHP"
yum-config-manager --enable remi-php72 >> $log 2>&1

yum -y install php php-mysqlnd php-curl php-simplexml \
php-devel php-gd php-json php-pecl-mcrypt php-mbstring php-opcache php-pear \
php-pecl-apcu php-pecl-geoip php-pecl-json-post php-pecl-memcache php-pecl-xmldiff \
php-pecl-zip php-pspell php-soap php-tidy php-xml php-xmlrpc php-fpm >> $log 2>&1

retval=$?
if [ "${retval}" -ne 0 ]; then
    prnterr "unable to install php"
fi

prntok

# configuring php
prntinfo "configuring PHP"

sed -i 's/^max_execution_time =.*/max_execution_time = 300/g' /etc/php.ini
sed -i 's/^memory_limit =.*/memory_limit = 256M/g' /etc/php.ini
sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 64M/g' /etc/php.ini
sed -i 's/^post_max_size =.*/post_max_size = 64M/g' /etc/php.ini
#sed -i 's{^;date.timezone =.*{date.timezone = "Asia/Jakarta"{g' /etc/php.ini
sed -i 's/^;opcache.revalidate_freq=2/opcache.revalidate_freq=60/g' /etc/php.d/10-opcache.ini
sed -i 's/^;opcache.fast_shutdown=0/opcache.fast_shutdown=1/g' /etc/php.d/10-opcache.ini

prntok

# configure php-fpm
prntinfo "configuring php-fpm"
mv /etc/php-fpm.d/www.conf{,.orig}
touch /etc/php-fpm.d/www.conf

cp -p /tmp/ngxinstall/config/php-fpm.tpl /etc/php-fpm.d/${domainname}.conf 

sed -i "s/%%domainname%%/${domainname}/g" /etc/php-fpm.d/${domainname}.conf
sed -i "s/%%username%%/${username}/g" /etc/php-fpm.d/${domainname}.conf

systemctl enable php-fpm >> $log 2>&1
systemctl start php-fpm >> $log 2>&1

fpmstts=$(systemctl is-active php-fpm)

if [ "${fpmstts}" == "active" ]; then
    prntok
else
    systemctl status php-fpm >> $log 2>&1
    prnterr "failed to start php-fpm"
fi

# install MariaDB
prntinfo "installing MariaDB"
cp -p /tmp/ngxinstall/config/mariadb.repo /etc/yum.repos.d/mariadb.repo

yum -y install MariaDB-server MariaDB-client MariaDB-compat MariaDB-shared >> $log 2>&1

retval=$?
if [ "${retval}" -ne 0 ]; then
    prnterr "unable to install MariaDB"
fi

systemctl enable mariadb >> $log 2>&1
systemctl start mariadb >> $log 2>&1

mrdbstts=$(systemctl is-active mariadb)

if [ "${mrdbstts}" == "active" ]; then
    prntok
else
    systemctl status mariadb >> $log 2>&1
    prnterr "failed to start mariadb"
fi

# configure MariaDB
prntinfo "configuring MariaDB"
mysqlpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")
mysqladmin -u root password "${mysqlpass}"

mysql -u root -p"${mysqlpass}" -e "UPDATE mysql.user SET Password=PASSWORD('${mysqlpass}') WHERE User='root'"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.user WHERE User=''"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
mysql -u root -p"${mysqlpass}" -e "FLUSH PRIVILEGES"

cat > ~/.my.cnf <<EOF
[client]
password = '${mysqlpass}'
EOF

chmod 600 ~/.my.cnf

prntok

# create MySQL database for Wordpress
prntinfo "creating Wordpress database"
wpdbpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")

cat > /tmp/create.sql <<EOF
create database ${username}_wp;
grant all privileges on ${username}_wp.* to ${username}_wp@localhost identified by '${wpdbpass}';
flush privileges;
EOF

mysql < /tmp/create.sql 
rm -rf /tmp/create.sql

prntok

# installing WPCLI
prntinfo "installing wpcli"
wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "unable to download wpcli"
fi

chmod 755 /usr/local/bin/wp

prntok

# install Wordpress
prntinfo "installing Wordpress"
cd /chroot/${username}/home/${username}/public_html
wpadminpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")

sudo -u ${username} bash -c "/usr/local/bin/wp core download" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp core config --dbname=${username}_wp --dbuser=${username}_wp --dbpass=${wpdbpass} --dbhost=localhost --dbprefix=wp_" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp core install --url=${domainname} --title='Just another Wordpress site' --admin_user=${username} --admin_password=${wpadminpass} --admin_email=${email}" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp plugin install really-simple-ssl wp-super-cache" >> $log 2>&1
prntok

# install letsencrypt certbot
prntinfo "installing letsencrypt certbot"
yum -y install certbot >> $log 2>&1
retval=$?

if [ "${retval}" -ne 0 ]; then
    prnterr "unable to install letsencrypt certbot"
fi

prntok

# configuring letsencrypt
prntinfo "configuring letsencrypt"

domipaddr=$(dig +short ${domainname})
svripaddr=$(curl -sSL http://cpanel.com/showip.cgi)

if [ "${domipaddr}" == "${svripaddr}" ]; then
    mkdir -p /etc/letsencrypt
    cp -p /tmp/ngxinstall/config/cli.ini /etc/letsencrypt/cli.ini 
    sed -i "s{%%email%%{${email}{g" /etc/letsencrypt/cli.ini
    
    # check if www record exist and add it to the pool
    wwwipaddr=$(dig +short www.${domainname})

    if [ "${wwwipaddr}" == "${svripaddr}" ]; then
        domargs="-d ${domainname} -d www.${domainname}"
    else
        domargs="-d ${domainname}"
    fi

    if [ "${ENV}" == "dev" ]; then
        extraargs="--staging"
    else
        extraargs=""
    fi

    # request certificate
    webroot="/chroot/${username}/home/${username}/public_html"
    certbot certonly --webroot -w ${webroot} ${domargs} ${extraargs}>> $log 2>&1
    retval=$?

    # check if certbot successfully issue certificate
    if [ "${retval}" -eq 0 ]; then
    
        # activate ssl section in nginx config
        sed -i "s{^#{{g" /etc/nginx/sites-enabled/${domainname}.conf

        # check if new configuration is ok
        /usr/sbin/nginx -t >> $log 2>&1
        retval=$?

        if [ "${retval}" -eq 0 ]; then
            # restart nginx
            /usr/sbin/nginx -s reload >> $log 2>&1
        else
            prntwarn "nginx config seem broken, consider to check the log"
        fi

        # install certbot autorenew cron
        echo "0 0,12 * * * /usr/bin/python -c 'import random; import time; time.sleep(random.random() * 3600)' && /usr/bin/certbot renew -q --post-hook 'systemctl restart nginx'" > /tmp/le.cron
        crontab /tmp/le.cron
        rm -rf /tmp/le.cron

        prntok
    
    else
        prntwarn "certbot can't issue certificate, check the log"
    fi

else
    prntwarn "skipped (IP address probably not pointed to this server)"
fi

# print all details
echo
echo "==========================================================================="
echo "SFTP"
echo "Domain name   : ${bold}${red}${domainname}${normal}"
echo "Username      : ${bold}${cyan}${username}${normal}"
echo "Password      : ${bold}${green}${password}${normal}"
echo "Document root : ${bold}${yellow}${webroot}${normal}"
echo
echo "Wordpress"
echo "Username      : ${bold}${cyan}${username}${normal}"
echo "Password      : ${bold}${green}${wpadminpass}${normal}"
echo "URL           : ${bold}${yellow}http://${domainname}/wp-admin/${normal}"
echo
echo "Don't forget to enable really-simple-ssl plugin when letsencrypt available,"
echo "and configure wp-super-cache as well. Enjoy!"
echo "==========================================================================="
echo

# clean all temporary files
rm -rf /tmp/ngxinstall /tmp/jailkit*

# exit and print duration
timeend=$(date +%s)
duration=$(echo $((timeend-timestart)) | awk '{print int($1/60)"m "int($1%60)"s"}')
printf "${green}▣▣▣ ${normal}time spent: ${bold}${yellow}${duration}${green} ▣▣▣${normal}\n\n"
