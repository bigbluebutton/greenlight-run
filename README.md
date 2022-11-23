# greenlight-run
A simple way to do a standalone deployment of Greenlight for development or production using docker-compose.

## Installation for devlopment (short version)

On an Ubuntu 20.04 machine (AWS EC2 instance, LXC container, VMWare machine etc).

### Fetching the scripts

```
git clone https://github.com/jfederico/greenlight-run
cd greenlight-run
git checkout dev-v3
```

### Initializing environment variables
Create a new .env file for greenlight based on the dotenv file included.

```
cp data/greenlight/dotenv data/greenlight/.env
```

Most required variables are pre-set by default, the ones that must be set before starting are:

```
SECRET_KEY_BASE=
PORT=
```

They can be added by editing the file or with sed.

```
sed -i "s/SECRET_KEY_BASE=.*/SECRET_KEY_BASE=$(openssl rand -hex 64)/" data/greenlight/.env
sed -i "s/PORT=.*/PORT=3080/" data/greenlight/.env
```

Create a new .env file for the deployment based on the dotenv file included.

```
cp dotenv .env
```

The only variable required is the domain name that will be used, since by default, the app will be exposed as gl.DOMAIN_NAME for greenlight and kc.DOMAIN_NAME for keycloak.
```
DOMAIN_NAME=
```

Also, when using the `init-letsencrypt.sh` script, you should add the email.

```
LETSENCRYPT_EMAIL=
```

## For using a SSL certificate signed by Let’s Encrypt, generate the certificates.

### Manual

```
certbot certonly --manual -d gl.<DOMAIN_NAME> --agree-tos --no-bootstrap --manual-public-ip-logging-ok --preferred-challenges=dns --email your@email.com --server https://acme-v02.api.letsencrypt.org/directory
```

#### Validate the Let’s Encrypt challenge

Respond yes to sharing the Email and IP

Take the string given as a challenge and create a TXT record on your DNS (see the prerequisites). You should set up the Challenge as indicated.

```
Performing the following challenges:
dns-01 challenge for gl.<DOMAIN_NAME>

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Please deploy a DNS TXT record under the name
_acme-challenge.gl.<DOMAIN_NAME> with the following value:

XdFPEeAvHmJGjDmmXsqvNPjYC74U_wjZFcqv4IrlDFM

Before continuing, verify the record is deployed.
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Press Enter to Continue
```

The record would be like:

```
gl.<DOMAIN_NAME>.	TXT	60	"XdFPEeAvHmJGjDmmXsqvNPjYC74U_wjZFcqv4IrlDFM"
```

Make sure to set 60 secs for the TTL, you may need to update it later and that will shorten the time you wait for the DNS to propagate.

Wait for 60 secs before hitting <Enter> on the console.

Now repeat the same procedure for `kc.<DOMAIN_NAME>`

Once that is done, you can copy the letsencrypt certificates to `data/certbot/config`

```
cp -R /etc/letsencrypt/config/* data/certbot/config
```

### Automated (on machines on the cloud holding a public IP and linked to a valid hostname)
```
./init-letsencrypt.sh
```

Start the services.

docker-compose up -d

Now, the greenlight server is running, but it is not quite yet ready. The database must be initialized.

For greenlight:
```
docker exec -i greenlight bundle exec rake db:setup
```

For keycloak:
```
docker exec -it postgres psql -U postgres -W
password
CREATE DATABASE keycloakdb
Ctrl-d
```

For development, we can use the local template by editing the variable `SITES_TEMPLATE=local` in `.env`. This will redirect the requests to your local rails app instead of doing so to the docker container.

Keep in mind that the port in the template is hard-coded to `3000`, but it can be edited (or sed)  directly at `data/nginx/sites.template-local`.

E.g.
```
sed -i "s/DOMAIN_NAME:.*/DOMAIN_NAME:5000/" data/nginx/sites.template-local
```

When keycloak is initialized, it also needs to be configured by adding a, and then set those values into the `data/greenlight/.env` file.

The env variables that need to be added are:
```
OPENID_CONNECT_CLIENT_ID=
OPENID_CONNECT_CLIENT_SECRET=
OPENID_CONNECT_ISSUER=
OPENID_CONNECT_REDIRECT=
```

## Setup
### Using keycloak with greenlight using OIDC

Log into Keycloak

(Optional) Create a realm for greenlight by hovering "master" dropdown and clicking new realm:
![image](https://user-images.githubusercontent.com/21375588/119866764-29a1e580-beeb-11eb-8a18-39370c39a5fb.png)

In realm settings > Login, enable user registration and remember to click save.\
In clients, click create and give an appropriate client id (Ex: `greenlight`)\
Set the access type to confidential, and fill out redirect url and web origins.
Ex configuration:
![image](https://user-images.githubusercontent.com/21375588/119872156-2873b700-bef1-11eb-91f5-d1bc291a0466.png)
Copy `Client ID` in the admin console on the same page and paste it into `greenlight/.env` under `OPENID_CONNECT_CLIENT_ID`\
Under the same page/client, click on the credentials tab and copy and paste it into `greenlight/.env` under `OPENID_CONNECT_CLIENT_SECRET`

Go back to the Realm settings on the sidebar and click on the link `OpenID Endpoint Configuration` where you will find the issuer.\
Copy the `issuer` and paste it into `greenlight/.env` under `OPENID_CONNECT_ISSUER`\
In addition, fill out the `OAUTH2_REDIRECT` with the appropriate URL.
Ex sample:
```
OPENID_CONNECT_CLIENT_ID=greenlight
OPENID_CONNECT_CLIENT_SECRET=mR5VCBMKQFmZlIATeTHniS42jHOKKWQf
OPENID_CONNECT_ISSUER=https://kc.jesus.123it.ca/auth/realms/master
OPENID_CONNECT_REDIRECT=https://gl.jesus.123it.ca/
```

Finally, restart the deployment and signing up using OIDC should be possible
