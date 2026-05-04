# shlink-nixos

A fully idiomatic NixOS flake providing a native (non-containerised)
[Shlink](https://shlink.io) deployment module for NixOS 25.11+.

## What this flake provides

| Output | Description |
|--------|-------------|
| `nixosModules.shlink` | NixOS module (also `nixosModules.default`) |
| `packages.<system>.shlink` | Shlink derivation built from source via `buildComposerProject` |

## Architecture

```
Internet
  │
  ▼
nginx  ── TLS termination, virtual host, static files
  │
  ▼  (FastCGI / unix socket)
php-fpm  ── Shlink PHP application
  │
  ├── PostgreSQL (optional local instance)
  └── /var/lib/shlink  (mutable state: GeoLite2 DB, Doctrine cache)

Systemd units (always present)
  └── shlink-init.{service}          oneshot: db:create + db:migrate on boot

Systemd units (only when geolite.enable = true)
  ├── shlink-geolite-update.{service,timer}   weekly GeoLite2 DB refresh
  └── shlink-visits-locate.{service,timer}    geolocate visits every 30 min
```

## Example usage

### Add the flake as input

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    shlink-nixos.url = "github:1ffycat/shlink-nixos";
    shlink-nixos.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, shlink-nixos, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system  = "x86_64-linux";
      modules = [
        ./configuration.nix
        shlink-nixos.nixosModules.shlink
      ];
    };
  };
}
```

### Configure the module

Minimal `configuration.nix`:

```nix
{ config, ... }: {

  services.shlink = {
    enable        = true;
    defaultDomain = "s.example.com";
    isHttps       = true;

    database = {
      driver        = "postgres";
      createLocally = true;
    };

    # Secrets via EnvironmentFile — never in the Nix store.
    # The file should contain lines such as:
    #   DB_PASSWORD=supersecret
    # or use the _FILE convention:
    #   DB_PASSWORD_FILE=/run/secrets/db-password
    environmentFiles = [ "/run/secrets/shlink" ];

    # Optional: enable geolocation (requires a free MaxMind account).
    geolite = {
      enable          = true;
      licenseKeyFile  = "/run/secrets/geolite-key";
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts."s.example.com" = {
      forceSSL   = true;
      enableACME = true;
      locations  = config.services.shlink.nginxLocations;
    };
  };
}
```

## Generate your first Shlink API key

```sh
sudo -u shlink \
  $(nix-store -q --references /run/current-system | grep shlink)/bin/cli \
  api-key:generate
```

Or add a convenience alias:

```nix
environment.shellAliases.shlink-cli =
  "sudo -u shlink ${config.services.shlink.package}/bin/cli";
```

Then: `shlink-cli api-key:generate`

## Updating Shlink

1. Bump `version` in `pkgs/shlink.nix`.
2. Re-run the `nix-prefetch-url` command and update `src.hash`.
3. Set `vendorHash = lib.fakeHash;`, run `nix build .#shlink 2>&1 | grep "got:"`, update `vendorHash`.
4. Run `nix flake update` and commit.

The `shlink-init` oneshot calls `db:migrate` on every boot, so schema migrations are automatic.

---

## Module option reference

### Core

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable Shlink |
| `package` | package | (flake) | Shlink derivation |
| `defaultDomain` | str (no `/`) | — | Short domain, e.g. `s.example.com` |
| `isHttps` | bool | `true` | Whether served over HTTPS |
| `basePath` | str (`/…` or `""`) | `""` | Path prefix if not at root |
| `timezone` | str | `system's timezone` | PHP timezone identifier |
| `memoryLimit` | str (`512M`, `-1`, …) | `"512M"` | PHP memory limit per worker |
| `logsFormat` | `console`\|`json` | `"json"` | Log output format |
| `cacheNamespace` | str | `"Shlink"` | Cache key prefix |
| `trustedProxies` | str\|null | `null` | Proxy count or IP list |
| `environmentFiles` | [path] | `[]` | Secret env files |
| `user` | str | `"shlink"` | System user |
| `group` | str | `"shlink"` | System group |

### URL shortening

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `shortCodesLength` | int (4–32) | `5` | Generated short code length |
| `autoResolveTitles` | bool | `true` | Resolve title from `<title>` tag |
| `shortUrlMode` | `strict`\|`loose` | `"strict"` | Short URL matching mode |
| `multiSegmentSlugs` | bool | `false` | Allow `/foo/bar/baz` slugs |

### Database (`database.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `driver` | enum | `"postgres"` | `postgres`, `mysql`, `maria`, or `sqlite` |
| `createLocally` | bool | `false` | Manage a local PostgreSQL DB |
| `name` | str | `"shlink"` | DB name |
| `user` | str | `"shlink"` | DB user |
| `host` | str | `"localhost"` | DB host |
| `port` | port\|null | `null` | DB port |
| `unixSocket` | path\|null | `null` | Unix socket path |
| `passwordFile` | path\|null | `null` | File containing DB password |

### Redirects (`redirects.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `statusCode` | 301\|302\|307\|308 | `302` | HTTP redirect status |
| `baseUrl` | str\|null | `null` | Redirect for bare base URL |
| `invalidShortUrl` | str\|null | `null` | Redirect for unknown codes |
| `regular404` | str\|null | `null` | Redirect for all other 404s |

### Tracking (`tracking.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `disable` | bool | `false` | Disable all tracking |
| `anonymizeRemoteAddr` | bool | `true` | Anonymise IPs (GDPR) |
| `orphanVisits` | bool | `true` | Track orphan visits |
| `disableIp` | bool | `false` | No IP / geo tracking |
| `disableReferrer` | bool | `false` | No referrer tracking |
| `disableUA` | bool | `false` | No user-agent tracking |

### GeoLite2 (`geolite.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable geolocation + create timers |
| `licenseKey` | str\|null | `null` | Key as plain string (store-unsafe) |
| `licenseKeyFile` | path\|null | `null` | Path to file with key |
| `updateCalendar` | str | `"weekly"` | systemd `OnCalendar` for DB update |

When `enable = false`: no `GEOLITE_LICENSE_KEY*` env var is set, Shlink disables
geolocation internally, and neither the update timer nor the visit-locate timer
is created.

### Redis (`redis.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `servers` | str\|null | `null` | Comma-separated Redis URIs |
| `sentinelService` | str\|null | `null` | Sentinel service name |

When `null` (default), Shlink uses local APCu cache — sufficient for single-instance use.

### Mercure (`mercure.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `publicHubUrl` | str\|null | `null` | Public Mercure hub URL |
| `internalHubUrl` | str\|null | `null` | Internal Mercure hub URL |
| `jwtSecret` | str\|null | `null` | JWT secret (prefer environmentFiles) |

When all three are `null` (default), real-time push updates are disabled.

### php-fpm (`phpfpm.settings`)

```nix
services.shlink.phpfpm.settings = {
  "pm.max_children" = 20;
  "pm.max_requests" = 1000;
};
```

## Secrets management

Any approach that writes a file works:

- **agenix** / **sops-nix**: decrypt to a path, pass to `environmentFiles`.
- **systemd credentials**: `LoadCredential` + reference `/run/credentials/…` from an env file.
- Plain files (`chmod 400`, owned by `shlink`).

All Shlink env vars support the `_FILE` suffix, so secrets never need to appear
in the environment directly.
