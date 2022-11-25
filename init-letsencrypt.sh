#!/bin/bash

## Script based on https://github.com/wmnnd/nginx-certbot
## https://pentacent.medium.com/nginx-and-lets-encrypt-with-docker-in-less-than-5-minutes-b4b8a60d3a71

# Script functions declaration:

usage() {
  echo -e "Usage: $0 [-z|-r|-h]\n"
  echo "$0 is a simple script that automates the issuing of letsencrypt certificates for Greenlight."
  echo "  -n|--non-interactive  Enable non interactive mode"
  echo "  -r|--replace          Replace existing certificates without asking"
  echo "  -h|--help             Show usage information"
}

docker_compose() {
  if [[ $composePlugin == 1 ]]; then
    docker compose "$@" 2> /dev/null # Redirecting stdout to null to suppress docker outputs.
  else
    docker-compose "$@" 2> /dev/null # Redirecting stdout to null to suppress docker outputs.
  fi

  return $?
}

catch_error() {
  [ ! $? -eq 0 ] && >&2 echo "$1" && exit 1
}

interactive=1
replaceExisting=0

while [[ $# -gt 0 ]]
do
    case "$1" in
        -n|--non-interactive) interactive=0;shift;;
        -r|--replace) replaceExisting=1;shift;;
        -h|--help) usage;exit;;
        -*) >&2 echo -e "Unknown option: \"$1\" ⛔ \n";usage;exit 1;;
        *) >&2 echo -e "Script does not accept arguments ⛔ \n";usage;exit 1;;
    esac
done

# Loading and checking Environment Variables:
echo "## Checking enviroment ⏳"

if [[ ! -f ./.env ]]; then
  >&2 echo ".env file does not exist on your filesystem ⛔"
  exit 1
fi

export $(cat .env | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )

if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
  >&2 echo "Required \$LETSENCRYPT_EMAIL variable is not set in .env ⛔"
  >&2 echo "Setting up an email for letsencrypt certificates is strongly recommended ❗"
  exit 1
fi

if [[ -z $DOMAIN_NAME ]]; then
  >&2 echo "Required \$DOMAIN_NAME variable is not set in .env ⛔"
  exit 1
fi

if [[ -z $GL_HOSTNAME ]]; then
  >&2 echo "Required \$GL_HOSTNAME is not set ⛔"
  exit 1
fi

# Checking installed compose version: 
if docker compose version &> /dev/null; then
  composePlugin=1
  echo "-> Detected docker compose plugin ✔"
elif docker-compose version &> /dev/null; then
  composePlugin=0
  echo "-> Unable to detect docker compose plugin 🛑"
  echo "-> Detected docker-compose utility ✔"
else
  >&2 echo 'No "docker-compose" or "docker compose" is installed ⛔'
  exit 1
fi
echo "-> Enviroment checked ✔"
echo


echo "## Preparing enviroment ⏳"

if [[ ! -z $GL_HOSTNAME ]]; then
  GL_FQDN="$GL_HOSTNAME.$DOMAIN_NAME"
fi

if [[ ! -z $KC_HOSTNAME ]]; then
  KC_FQDN="$KC_HOSTNAME.$DOMAIN_NAME"
fi

IFS=' '
domains="$GL_FQDN $KC_FQDN"
domains=($domains)
rsa_key_size=4096
data_path="./data/certbot/conf"
web_root="./data/certbot/www"
email="$LETSENCRYPT_EMAIL" # Adding a valid address is strongly recommended.

echo "-> Prepared enviroment successfully ✔"
echo "-> Attempting to issue Let's Encrypt certificates for '${domains[@]}' for the email address of '$email' ⏳"
echo
echo "-> Let's encrypt certificate files will be stored under '$data_path' ❕"
echo "-> '$web_root' will be the web root for the HTTP-01 ACME challenge ❕"
echo

if [ -d "$data_path" ] && [ "$replaceExisting" -eq 0 ]; then
    if [ "$interactive" -eq 0 ]; then
      echo "-> Certificates already exist under '$data_path' 🛑"
      exit
    fi

    read -p "Existing certificates data found. Continue and replace ? (y/N) ❔ " decision
    if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
      exit
    fi
fi

mkdir -p "$data_path" "$web_root"

# Load TLS parameters:
if [ ! -e "$data_path/options-ssl-nginx.conf" ] || [ ! -e "$data_path/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended nginx TLS parameters ⏳"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/options-ssl-nginx.conf"
  catch_error "Failed to download recommended TLS parameter 'options-ssl-nginx.conf' ⛔"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/ssl-dhparams.pem"
  catch_error "Failed to download recommended TLS parameter 'ssl-dhparams.pem' ⛔"
  echo "-> Downloaded recommended nginx  TLS parameters ✔"
  echo
fi

# Chicken and egg problem resolution:
cert_path="$data_path/live/${domains[0]}"

if  [ ! -f "$cert_path/fullchain.pem" ] && [ ! -f "$cert_path/privkey.pem" ]; then
  echo "-> Creating dummy certificate for '${domains[0]}' ⏳"
  mkdir -p $cert_path
  rm -rfv $cert_path/* # In case of having directories as cert files, caused by running Keycloak before running this script.

  openssl req -x509 -nodes -newkey rsa:2048 -days 1\
    -keyout "$cert_path/privkey.pem" \
    -out "$cert_path/fullchain.pem" \
    -subj "/CN=${domains[0]}"
  echo
fi

echo "### Starting nginx ⏳"
docker_compose up --force-recreate -d nginx
catch_error "Failed to start NGINX ⛔"
echo "-> Started nginx ✔"
echo

echo "### Deleting exisiting certificates for '${domains[@]}' ⏳"
rm -rfv "$data_path/live/" "$data_path/archive/" "$data_path/renewal/"
echo

echo "### Requesting Let's Encrypt certificates for '${domains[@]}' for the email address of '$email' ⏳"

domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Generating certificates
for staging in 1 0; do
  if [ $staging != "0" ]; then
    echo "-> Running in staging mode [Rehearsal] 🟡"
  else
    echo "-> Rehearsal passed ✔"
    echo "-> One more step to go ❕"
    echo "-> Generating production certificates for '${domains[@]}' ⏳"
  fi

  docker_compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      $([ "$staging" -eq 1 ] && echo '--staging') \
      $([ "$interactive" -ne 1 ] && echo '--non-interactive') \
      $domain_args \
      --email $email \
      --rsa-key-size $rsa_key_size \
      --agree-tos \
      --debug-challenges \
      --force-renewal" certbot

  catch_error "Failed to generate certificates ⛔"
  echo

  echo "### Reloading nginx..."
  docker_compose exec $([ "$interactive" -ne 1 ] && echo "-T") nginx nginx -s reload
  catch_error "Failed to reload NGINX ⛔"

  echo "-> Reloaded nginx ✔"
  echo "DONE ✔"
  echo
done

echo "You're all set, Bye ❕"

