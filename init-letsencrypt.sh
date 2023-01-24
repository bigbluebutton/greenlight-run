#!/bin/bash

if docker compose version &> /dev/null; then
  composePlugin=1
  echo "-> Detected docker compose plugin ✔"
elif docker-compose version &> /dev/null; then
  composePlugin=0
  echo "-> Unable to detect docker compose plugin 🛑"
  echo "-> Detected docker-compose utility ✔"
else
  >&2 echo 'No "docker-compose" or "docker compose" is installed ⛔'
fi

if [[ ! -f ./.env ]]; then
  >&2 echo ".env file does not exist on your filesystem ⛔"
  exit 1
fi

# Local .env
if [ -f .env ]; then
    # Load Environment Variables
    export $(cat .env | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
  >&2 echo "Setting up an email for letsencrypt certificates is strongly recommended ❗"
  exit 1
fi

if [[ -z $DOMAIN_NAME ]]; then
  >&2 echo "DOMAIN_NAME env variable is not set in .env ⛔"
  exit 1
fi

if [[ -z $GL_HOSTNAME ]] && [[ -z $KC_HOSTNAME ]]; then
  >&2 echo "NO FQDN is set ⛔"
  exit 1
fi

# Functions
usage() {
  >&2 echo -e "Initializes letsencrypt certificates for Nginx proxy container\n"
  >&2 echo -e "Usage: $0 [-n|-r|-h]\n"
  >&2 echo "  -n|--non-interactive  Enable non interactive mode"
  >&2 echo "  -r|--replace          Replace existing certificates without asking"
  >&2 echo "  -h|--help             Show usage information"
  exit 1
}

docker_compose() {
  if [[ $composePlugin == 1 ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi

  return $?
}

interactive=1
replaceExisting=0

while [[ $# -gt 0 ]]
do
    case "$1" in
        -n|--non-interactive) interactive=0;shift;;
        -r|--replace) replaceExisting=1;shift;;
        -h|--help) usage;;
        -*) echo "Unknown option: \"$1\"\n";usage;;
        *) echo "Script does not accept arguments\n";usage;;
    esac
done

echo "### Preparing enviroment..."

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
data_path="./data/certbot"
email="$LETSENCRYPT_EMAIL" # Adding a valid address is strongly recommended.
staging=${LETSENCRYPT_STAGING:-1}
echo "-> Prepared enviroment successfully ✔"
echo "-> Requesting Let's Encrypt certificate for ${domains[@]} for the email address of '$email' ⏳"
echo "-> Certificate files will be stored under '$data_path' ❕"
echo

if [ -d "$data_path" ] && [ "$replaceExisting" -eq 0 ]; then
    if [ "$interactive" -eq 0 ]; then
      echo "-> Certificates already exist."
      exit
    fi

    read -p "Existing data found. Continue and replace existing certificate? (y/N) ❔ " decision
    if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
      exit
    fi
fi

if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Requesting Let's Encrypt certificate for ${domains[@]} ⏳"
### Preparing args:
# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then
  staging_arg="--staging"
  echo "-> Running in staging mode 🟡"
fi

docker_compose restart nginx

for domain in ${domains[@]}; do
  domain_args="-d '$domain'"
  echo "-> Requesting Let's Encrypt certificate for $domain ⏳"
  docker_compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $([ "$interactive" -ne 1 ] && echo '--non-interactive') \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --debug-challenges \
    --force-renewal" certbot
  echo
done
