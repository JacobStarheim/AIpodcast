# Deploying to a server

This guide runs the backend (API, worker, PostgreSQL with pgvector) on one small
Linux server with Docker, behind Caddy for automatic HTTPS, and then puts the
iPhone app on TestFlight against it.

The files involved:

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build with two targets: `api` (also runs migrations and admin scripts) and `worker` (includes FFmpeg). Both run as the unprivileged `node` user with `NODE_ENV=production`. |
| `.dockerignore` | Keeps `node_modules`, `.git`, `.local`, the Flutter app and every `.env` file out of the build. |
| `infrastructure/docker-compose.prod.yml` | The production stack: `postgres`, `migrate`, `api`, `worker`, `caddy`. |
| `infrastructure/Caddyfile` | HTTPS for `DOMAIN` and the reverse proxy to the API. |
| `infrastructure/.env.prod.example` | Every setting with a short explanation. Copy to `infrastructure/.env.prod`. |

## What you have to decide first

- **Server provider and region.** Any provider with a plain Linux VM works
  (for example Hetzner, DigitalOcean, Linode/Akamai, Vultr, Scaleway). A region
  close to you keeps answers fast.
- **A domain name** and access to its DNS settings. Apple requires HTTPS for the
  app, and HTTPS needs a name; a subdomain such as `podcast.example.com` is fine.
- **An OpenAI account** with access to the configured models, and a monthly
  budget limit set in the OpenAI dashboard.
- **An Apple Developer Program membership** for TestFlight (see the last section).
- **Where off-server backups go** (another machine, or object storage).

## Server size

| | Minimum | Recommended |
| --- | --- | --- |
| CPU | 2 vCPU | 2–4 vCPU |
| Memory | 2 GB plus 2 GB swap | 4 GB |
| Disk | 40 GB | 80 GB or an attached volume |
| OS | Ubuntu 24.04 LTS or Debian 12, x86-64 or ARM64 | |

The images are built on the server, which needs about 1 GB of free memory
during the build. Disk use grows mostly with stored episode audio (roughly
50–120 MB per hour of audio); transcripts and embeddings take a few MB per
episode-hour. Docker images and build cache take about 3 GB.

## 1. Create the server

Create the VM with your SSH key. Then log in as root once and add a user for
deployment:

```bash
adduser --gecos "" deploy     # the password you choose is only used for sudo
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh && cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
```

Make sure SSH accepts keys only (`PasswordAuthentication no` in
`/etc/ssh/sshd_config`, then `systemctl restart ssh`), and keep the OS patched
(`sudo apt update && sudo apt upgrade`; consider the `unattended-upgrades`
package).

## 2. Point the domain at the server

At your DNS provider, create an **A record** for the API host name (for example
`podcast.example.com`) with the server's public IPv4 address. If the server has
IPv6, add an **AAAA record** too, or none at all (a wrong AAAA record breaks
certificate issuance). Check from your own machine before continuing:

```bash
dig +short podcast.example.com
```

It must print the server's address. Caddy requests the certificate on first
start; repeated failures because DNS is not ready yet can hit Let's Encrypt's
rate limits for an hour.

## 3. Firewall: allow only SSH, HTTP and HTTPS

Prefer the provider's cloud firewall if it has one (inbound TCP 22, 80, 443 and
UDP 443; deny everything else). On the server itself:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443        # TCP for HTTPS, UDP for HTTP/3
sudo ufw enable
```

Docker writes its own firewall rules for published ports and bypasses `ufw`.
That is why only Caddy publishes ports in the compose file; PostgreSQL has no
host port at all. Do not add `ports:` to other services.

## 4. Install Docker

Install Docker Engine with the Compose plugin from Docker's own apt repository,
following <https://docs.docker.com/engine/install/ubuntu/> (or the Debian page).
The distribution's `docker.io` package can be too old. Then:

```bash
sudo usermod -aG docker deploy    # log out and in again afterwards
docker compose version            # v2.24 or newer
```

Membership in the `docker` group is equivalent to root on this machine; give it
only to the deploy user.

## 5. Get the code and the settings

As `deploy`:

```bash
sudo mkdir -p /opt/podcast-ai && sudo chown deploy:deploy /opt/podcast-ai
git clone https://github.com/JacobStarheim/AIpodcast.git /opt/podcast-ai
cd /opt/podcast-ai
```

If the repository is private, add a read-only deploy key to the repository on
GitHub and clone over SSH instead.

Create the settings file. Either fill it in on the server:

```bash
cp infrastructure/.env.prod.example infrastructure/.env.prod
chmod 600 infrastructure/.env.prod
openssl rand -hex 32    # run once per secret: POSTGRES_PASSWORD, ADMIN_KEY, MEDIA_URL_SECRET
nano infrastructure/.env.prod
```

or prepare it on your own machine and copy it over:

```bash
scp infrastructure/.env.prod deploy@SERVER:/opt/podcast-ai/infrastructure/.env.prod
ssh deploy@SERVER chmod 600 /opt/podcast-ai/infrastructure/.env.prod
```

Required: `DOMAIN`, `POSTGRES_PASSWORD`, `OPENAI_API_KEY`, `ADMIN_KEY`,
`MEDIA_URL_SECRET`. Everything else has a working default; the example file
explains each value. The file is git-ignored; keep a copy in your password
manager, since the database password and media secret cannot be recovered.

`APP_API_KEY` stays empty in production, where people sign in with their own
accounts. Versions of the API from before user accounts require it and refuse
to start without it.

## 6. Start

Every command below runs from `/opt/podcast-ai`. A shell alias saves typing:

```bash
alias dc='docker compose -f infrastructure/docker-compose.prod.yml --env-file infrastructure/.env.prod'
echo "alias dc='docker compose -f infrastructure/docker-compose.prod.yml --env-file infrastructure/.env.prod'" >> ~/.bashrc
```

Build and start everything:

```bash
dc up -d --build
```

Compose builds the images, starts PostgreSQL, runs `migrate` once (it applies
pending migrations and exits), starts `api` and `worker` after it succeeded, and
starts `caddy` once the API is healthy. The first build takes a few minutes.

## 7. Check that it works

```bash
dc ps -a                     # migrate: exited (0); postgres and api: healthy; worker and caddy: running
dc logs migrate              # "Applied 00x_....sql" or "Database schema is up to date."
curl https://podcast.example.com/health      # {"ok":true}
dc logs -f api worker caddy  # Ctrl-C to stop following
```

If `curl` fails with a certificate error, read `dc logs caddy`: usually DNS
does not point at the server yet, or ports 80/443 are blocked.

## 8. Create the first account

`scripts/create-user.mjs` runs inside the API image. The password is read from
the `USER_PASSWORD` environment variable, so it does not end up in the shell
history or the process list:

```bash
read -rsp 'Password: ' USER_PASSWORD; echo; export USER_PASSWORD
dc run --rm -e USER_PASSWORD api node scripts/create-user.mjs --email you@example.com --name "Your Name"
unset USER_PASSWORD
```

## Updating to a new version

```bash
cd /opt/podcast-ai
# back up first (see below), then:
git pull --ff-only            # or: git fetch --tags && git checkout <tag>
dc build --pull               # also picks up security updates of the base images
dc run --rm migrate           # apply new migrations while the old version keeps serving
dc up -d                      # replace api and worker with the new version
dc restart caddy              # only if infrastructure/Caddyfile changed
dc ps -a && curl https://podcast.example.com/health
docker image prune -f         # remove old, unused images
```

`migrate` also runs on every `up`, before the API and worker start, so a plain
`dc up -d --build` works too. Running it separately first is safer: if a
migration fails, `dc run` stops with the error and the running version is not
touched. With `up`, the old API and worker are already stopped at that point
and stay down until the cause is fixed (`dc logs migrate`). Migrations only go
forward: to roll back to an older version whose code expects an older schema,
restore the database backup taken before the update.

After changing `infrastructure/.env.prod`, run `dc up -d` to recreate the
affected containers.

## Backups

### Database (nightly)

Create the backup directory once:

```bash
sudo mkdir -p /var/backups/podcast-ai && sudo chown deploy:deploy /var/backups/podcast-ai
```

Then add this line with `crontab -e` as `deploy` (one line; `%` must be escaped
in crontab). It writes a compressed dump at 03:30 every night and keeps 14 days:

```cron
30 3 * * * cd /opt/podcast-ai && docker compose -f infrastructure/docker-compose.prod.yml --env-file infrastructure/.env.prod exec -T postgres pg_dump -U podcast -d podcast_ai -Fc > /var/backups/podcast-ai/db.tmp && mv /var/backups/podcast-ai/db.tmp /var/backups/podcast-ai/db-$(date +\%F).dump && find /var/backups/podcast-ai -name 'db-*.dump' -mtime +14 -delete
```

A backup on the same disk does not survive losing the server. Copy
`/var/backups/podcast-ai` elsewhere regularly, for example with `rsync` to
another machine or `rclone`/`restic` to object storage, and test a restore now
and then.

Restore a dump (stops the services that use the database first):

```bash
dc stop api worker
dc exec -T postgres pg_restore -U podcast -d podcast_ai --clean --if-exists --single-transaction < /var/backups/podcast-ai/db-YYYY-MM-DD.dump
dc up -d
```

### Episode audio

Downloaded episode audio lives in the Docker volume `podcast_ai_prod_audio_data`
(mounted at `/data/audio` in `api` and `worker`). Most of it can be downloaded
again from the feeds, so a weekly copy is usually enough; back it up more often
if feeds remove old episodes. It can be large, so check the free space first:

```bash
docker run --rm -v podcast_ai_prod_audio_data:/data/audio:ro -v /var/backups/podcast-ai:/backup \
  node:20-bookworm-slim tar -cf /backup/audio-$(date +%F).tar -C /data/audio .
```

Restore with the same command, mounting the volume without `:ro` and running
`tar -xpf /backup/audio-YYYY-MM-DD.tar -C /data/audio`.

The certificates in `podcast_ai_prod_caddy_data` need no backup; Caddy
requests new ones if they are missing.

## Operations

```bash
dc ps -a                            # state and health of every service
dc logs --since 1h worker           # recent worker output (imports, transcription)
dc restart worker                   # restart one service
dc exec postgres psql -U podcast -d podcast_ai   # SQL shell; see RUNBOOK.md for queries
df -h && docker system df           # disk use
```

Container logs are rotated by Docker (5 files of 10 MB per service). The
services restart automatically after a crash or a reboot. PostgreSQL is
reachable only by `migrate`, `api` and `worker` on an internal Docker network.

## Monthly costs

Approximate; check current prices before deciding.

- **Server**: a 2 vCPU / 4 GB VM costs roughly €5–10 a month at budget
  providers and about $20–25 at DigitalOcean, Linode or Vultr. Extra disk
  volumes for audio are a few cents per GB per month.
- **Domain**: about $10–20 a year.
- **OpenAI** (usually the largest item):
  - Episode transcription is billed per audio minute. `DAILY_TRANSCRIPTION_MINUTES`
    caps it: the maximum monthly spend is about
    `DAILY_TRANSCRIPTION_MINUTES × 30 × price per minute`. For example, at
    $0.006 per minute the default cap of 180 minutes a day is at most about
    $33 a month; look up the actual price of the configured transcription model.
  - Each question costs a planning call and an answer call (a few thousand
    input tokens of transcript excerpts), plus speech-to-text for recorded
    questions and audio output for spoken answers. Spoken answers cost
    noticeably more than text answers.
  - Summaries and embeddings are small per episode.
- **Backups off the server**: object storage costs cents per GB per month.
- **Apple Developer Program**: 99 USD a year (needed for TestFlight).

Set a monthly budget and alerts in the OpenAI dashboard.

## Putting the app on an iPhone with TestFlight

The app talks to the server over HTTPS. iOS App Transport Security blocks plain
HTTP and certificates that the phone does not trust; the app only has an
exception for local networks during development. That is why the server runs
Caddy with a Let's Encrypt certificate for a real domain. A `DOMAIN=localhost`
setup does not work on a phone.

What you need:

- A Mac with Xcode and Flutter (see `apps/mobile_flutter/README.md`).
- A paid **Apple Developer Program** membership (99 USD a year). Enrolling as an
  individual takes up to about two days; an organization also needs a D-U-N-S
  number.
- The server running at `https://<your domain>` and an account created with
  `create-user.mjs` (also useful as the sign-in for Apple's beta review).

Steps:

1. **Register the bundle ID.** In the Apple Developer portal, under
   Certificates, Identifiers & Profiles > Identifiers, register an explicit App
   ID `io.github.jacobstarheim.aipodcast` (the bundle ID in the Xcode project).
   Xcode can also create it automatically in step 3.
2. **Create the app record.** In App Store Connect > Apps > "+" > New App: iOS,
   a name that is unique on the App Store, primary language, the bundle ID from
   step 1, and any SKU (for example `aipodcast`).
3. **Set up signing.** Open `apps/mobile_flutter/ios/Runner.xcworkspace` in
   Xcode, select the Runner target > Signing & Capabilities, choose your team and
   keep "Automatically manage signing" on.
4. **Build.** Every upload needs a higher build number (the part after `+` in
   `pubspec.yaml`, or `--build-number`):

   ```bash
   cd apps/mobile_flutter
   flutter pub get
   flutter build ipa --release --build-number 2 \
     --dart-define=API_BASE_URL=https://podcast.example.com
   ```

   The result is `build/ios/ipa/*.ipa` and the archive
   `build/ios/archive/Runner.xcarchive`. Do not compile secrets into the app:
   with user accounts no `API_KEY` define is needed, and anything passed with
   `--dart-define` can be extracted from the app.
5. **Upload**, either way:
   - **Transporter** (free on the Mac App Store): sign in with your Apple ID,
     drag the `.ipa` into the window, choose Deliver.
   - **Xcode Organizer**: `open build/ios/archive/Runner.xcarchive`, then in
     the Organizer choose Distribute App > App Store Connect > Upload.
6. **Release to testers.** After processing (usually 5–30 minutes) the build
   appears under the app's TestFlight tab. Answer the export compliance
   question (an app that only uses the system's HTTPS typically qualifies for
   the exemption; check Apple's guidance). Then either:
   - add **internal testers**: people on your App Store Connect team, up to
     100, available immediately; or
   - create an **external group** (by email or public link, up to 10,000).
     The first build of each version goes through Beta App Review, which needs
     a short description, a contact email and a test account to sign in with.
7. **Install.** On the iPhone, install the TestFlight app from the App Store,
   open the invitation (email or link) and install the app. Allow the
   microphone when asked, to record questions. TestFlight builds expire after
   90 days; upload a new build before then.

## Checklist of what only the owner can do

- Choose and pay for the server provider; create the VM and SSH key.
- Buy or pick the domain and create the DNS A (and AAAA) record.
- Create the OpenAI API key, check model access, set a budget limit.
- Fill in `infrastructure/.env.prod` and keep a copy of its secrets.
- Decide where off-server backups go and set up the copy job.
- Enroll in the Apple Developer Program, create the App Store Connect app,
  choose the app name and the testers.
- Decide who gets accounts and create them with `create-user.mjs`.
