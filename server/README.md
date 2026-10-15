# Horizon Web backend

A FastAPI server for a browser version of Horizon: accounts with admin and
user roles, per-user chats, and a proxy to one Ollama server that keeps the
Ollama address and token server-side and limits non-admins to the models
already loaded plus cloud ones. It serves the API and the Flutter web bundle
from one origin, so there is no CORS to get wrong.

**Status: backend only.** The API is built and tested; the Flutter web front
end it would serve has not been started, CI builds no web target, and no
release ships it. The app in `lib/` does not depend on anything here.

## Run it

```bash
cp .env.example .env         # set SESSION_SECRET and BOOTSTRAP_ADMIN_PASSWORD
docker build -t horizon-web .
docker run -d --env-file .env -p 8080:8080 -v horizon-web:/data horizon-web
```

Configuration is entirely from the environment; `.env.example` lists every
variable with its default. The SQLite database lives at `/data/horizon-web.db`
and the web bundle, once there is one, is served from `/srv/web`.
