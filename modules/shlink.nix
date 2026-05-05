# Deployment model
# ─────────────────
# • Shlink's PHP code is served by php-fpm.
# • nginx acts as the public-facing reverse proxy / TLS terminator.
# • An optional managed PostgreSQL database is supported.
# • All Shlink configuration is delivered via environment variables
#   (Shlink >= 2.9 supports this natively; no interactive install needed).
# • Secrets (DB password, GeoLite key, …) should be provided through
#   systemd's EnvironmentFile or any secrets manager that writes files,
#   using Shlink's <VAR>_FILE convention.
#
# Quick-start example:
#
#   services.shlink = {
#     enable        = true;
#     defaultDomain = "s.example.com";
#     isHttps       = true;
#     database.driver        = "postgres";
#     database.createLocally = true;
#     environmentFiles       = [ "/run/secrets/shlink" ];
#     # For geolocation, also set:
#     geolite.enable          = true;
#     geolite.licenseKeyFile  = "/run/secrets/geolite-key";
#   };
#
#   services.nginx.virtualHosts."s.example.com" = {
#     forceSSL  = true;
#     enableACME = true;
#     locations = config.services.shlink.nginxLocations;
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.shlink;

  # PHP-FPM's INI parser treats the keywords false/no/off as empty string,
  # causing "empty value" errors for env[] directives. "1"/"0" are plain
  # strings that PHP-FPM accepts, and PHP's (bool) cast maps them correctly.
  boolToEnv = b: if b then "1" else "0";

  # ── PHP interpreter with all extensions Shlink requires ──────────────
  phpWithExts = pkgs.php84.buildEnv {
    extensions = ({ enabled, all }: enabled ++ (with all; [
      curl intl gd gmp apcu pdo
      (if cfg.database.driver == "postgres" then pdo_pgsql
       else if cfg.database.driver == "mysql" || cfg.database.driver == "maria" then pdo_mysql
       else pdo_sqlite)
    ]));
    extraConfig = ''
      date.timezone = ${cfg.timezone}
      memory_limit  = ${cfg.memoryLimit}
    '';
  };

  shlinkPkg = cfg.package;
  poolName  = "shlink";
  stateDir  = "/var/lib/shlink";

  # ── Helpers ───────────────────────────────────────────────────────────

  # Produce a URI string from a host + optional port, used for redirect
  # URL values that are typed as lib.types.str but validated by assertions.
  # (Pure helper; not called in hot paths.)
  urlFrom = host: port: driver:
    let defaultPort = { postgres = 5432; mysql = 3306; maria = 3306; sqlite = null; };
    in if port != null then "${host}:${builtins.toString port}"
       else host;

  # ── Build the env-var set from module options ─────────────────────────
  # null values are stripped so Shlink falls back to its own defaults.
  shlinkEnv = lib.filterAttrs (_: v: v != null) {
    DEFAULT_DOMAIN              = cfg.defaultDomain;
    IS_HTTPS_ENABLED            = boolToEnv cfg.isHttps;
    BASE_PATH                   = if cfg.basePath != "" then cfg.basePath else null;
    TIMEZONE                    = cfg.timezone;
    MEMORY_LIMIT                = cfg.memoryLimit;
    LOGS_FORMAT                 = cfg.logsFormat;
    CACHE_NAMESPACE             = cfg.cacheNamespace;
    TRUSTED_PROXIES             = cfg.trustedProxies;

    # URL shortening
    DEFAULT_SHORT_CODES_LENGTH  = builtins.toString cfg.shortCodesLength;
    AUTO_RESOLVE_TITLES         = boolToEnv cfg.autoResolveTitles;
    SHORT_URL_MODE              = cfg.shortUrlMode;
    MULTI_SEGMENT_SLUGS_ENABLED = boolToEnv cfg.multiSegmentSlugs;

    # Database
    DB_DRIVER      = cfg.database.driver;
    DB_NAME        = cfg.database.name;
    DB_USER        = cfg.database.user;
    # When createLocally=true, PostgreSQL uses peer auth (no password) via
    # Unix socket. Setting host to the socket directory avoids TCP, which
    # requires a password even for local connections.
    DB_HOST        = if cfg.database.driver == "sqlite" then null
                     else if cfg.database.createLocally then null
                     else cfg.database.host;
    DB_PORT        = if cfg.database.port != null then builtins.toString cfg.database.port else null;
    DB_UNIX_SOCKET = if cfg.database.createLocally && cfg.database.unixSocket == null
                     then "/run/postgresql"
                     else cfg.database.unixSocket;

    # Redirects
    REDIRECT_STATUS_CODE               = builtins.toString cfg.redirects.statusCode;
    DEFAULT_BASE_URL_REDIRECT          = cfg.redirects.baseUrl;
    DEFAULT_INVALID_SHORT_URL_REDIRECT = cfg.redirects.invalidShortUrl;
    DEFAULT_REGULAR_404_REDIRECT       = cfg.redirects.regular404;

    # Visit tracking
    DISABLE_TRACKING          = boolToEnv cfg.tracking.disable;
    ANONYMIZE_REMOTE_ADDR     = boolToEnv cfg.tracking.anonymizeRemoteAddr;
    TRACK_ORPHAN_VISITS       = boolToEnv cfg.tracking.orphanVisits;
    DISABLE_IP_TRACKING       = boolToEnv cfg.tracking.disableIp;
    DISABLE_REFERRER_TRACKING = boolToEnv cfg.tracking.disableReferrer;
    DISABLE_UA_TRACKING       = boolToEnv cfg.tracking.disableUA;

    # GeoLite2 — only included when geolocation is enabled
    GEOLITE_LICENSE_KEY = if cfg.geolite.enable then cfg.geolite.licenseKey else null;

    # Redis
    REDIS_SERVERS          = cfg.redis.servers;
    REDIS_SENTINEL_SERVICE = cfg.redis.sentinelService;

    # Mercure
    MERCURE_PUBLIC_HUB_URL  = cfg.mercure.publicHubUrl;
    MERCURE_INTERNAL_HUB_URL = cfg.mercure.internalHubUrl;
    MERCURE_JWT_SECRET      = cfg.mercure.jwtSecret;
  };

  # Env vars that reference secret files — merged in wherever shlinkEnv is used
  secretEnv = lib.filterAttrs (_: v: v != null) {
    DB_PASSWORD_FILE = cfg.database.passwordFile;
    GEOLITE_LICENSE_KEY_FILE =
      if cfg.geolite.enable then cfg.geolite.licenseKeyFile else null;
  };

  # NixOS-specific runtime paths; never exposed as module options because
  # they are implementation details of this packaging.
  nixEnv = {
    # container.php calls chdir() here so all relative data/* paths land in
    # the writable state directory rather than the read-only Nix store.
    SHLINK_WORK_DIR = "${stateDir}/work";
    # Overrides the __DIR__-based lock/geolite paths in zz-nixos-paths.global.php.
    SHLINK_DATA_DIR = "${stateDir}/data";
    # Any non-empty value makes Shlink log to stderr instead of a file.
    SHLINK_RUNTIME  = "nixos";
  };

  # The full env passed to every Shlink process
  fullEnv = shlinkEnv // secretEnv // nixEnv;

  # Shared systemd service hardening applied to every Shlink unit
  hardenedServiceConfig = {
    User                 = cfg.user;
    Group                = cfg.group;
    EnvironmentFile      = lib.mkIf (cfg.environmentFiles != []) cfg.environmentFiles;
    PrivateTmp           = true;
    ProtectSystem        = "strict";
    ProtectHome          = true;
    ReadWritePaths       = [ stateDir ];
    NoNewPrivileges      = true;
    CapabilityBoundingSet = "";
    RestrictNamespaces   = true;
    LockPersonality      = true;
    RestrictRealtime     = true;
  };

in {
  # ── Options ────────────────────────────────────────────────────────────
  options.services.shlink = {

    enable = lib.mkEnableOption "Shlink URL shortener";

    package = lib.mkPackageOption pkgs "shlink" {
      default = [ "shlink" ];
      extraDescription = "Override to use a custom Shlink derivation.";
    };

    defaultDomain = lib.mkOption {
      type    = lib.types.strMatching "[^/]+";   # no slashes; must be a bare domain
      example = "s.example.com";
      description = "Short domain served by this Shlink instance (e.g. `s.example.com`).";
    };

    isHttps = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Whether Shlink is accessed over HTTPS. Does not configure TLS itself.";
    };

    basePath = lib.mkOption {
      type    = lib.types.strMatching "(/[^/].*)?";  # empty string or /something
      default = "";
      example = "/shlink";
      description = "Path prefix when Shlink is not served from the domain root. Must start with `/`.";
    };

    timezone = lib.mkOption {
      type    = lib.types.strMatching "[A-Za-z_]+(/[A-Za-z_]+)*";
      default = if config.time.timeZone != null then config.time.timeZone else "UTC";
      example = "Europe/Berlin";
      description = "PHP timezone for all dates stored by Shlink. See https://www.php.net/timezones";
    };

    memoryLimit = lib.mkOption {
      # PHP shorthand: digits followed by optional K/M/G, or -1
      type    = lib.types.strMatching "(-1|[0-9]+[KMGkmg]?)";
      default = "512M";
      example = "256M";
      description = "PHP `memory_limit` per worker process. Accepts PHP shorthand (e.g. `256M`, `1G`).";
    };

    logsFormat = lib.mkOption {
      type    = lib.types.enum [ "console" "json" ];
      default = "json";
      description = "Shlink log output format.";
    };

    cacheNamespace = lib.mkOption {
      type    = lib.types.str;
      default = "Shlink";
      description = "Cache key prefix. Set a unique value when multiple Shlink instances share a cache.";
    };

    trustedProxies = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      example = "1";
      description = ''
        Number of proxies in front of Shlink, or a comma-separated list of
        their IP addresses / CIDR blocks. Required when behind more than one
        reverse proxy to correctly resolve visitor IPs.
      '';
    };

    # ── URL shortening ──────────────────────────────────────────────────
    shortCodesLength = lib.mkOption {
      type    = lib.types.ints.between 4 32;
      default = 5;
      description = "Default generated short code length. Must be at least 4.";
    };

    autoResolveTitles = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Auto-resolve a short URL's title from the long URL's `<title>` tag.";
    };

    shortUrlMode = lib.mkOption {
      type    = lib.types.enum [ "strict" "loose" ];
      default = "strict";
      description = "`strict`: only exact short codes match. `loose`: case-insensitive matching.";
    };

    multiSegmentSlugs = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = "Allow multi-segment custom slugs such as `/campaign/2024/promo`.";
    };

    # ── Database ────────────────────────────────────────────────────────
    database = {
      driver = lib.mkOption {
        type    = lib.types.enum [ "postgres" "mysql" "maria" "sqlite" ];
        default = "postgres";
        description = "Database backend. `sqlite` is for testing only — not supported in production.";
      };

      createLocally = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = ''
          Create and manage a local PostgreSQL database for Shlink via
          `services.postgresql`. Only valid when `driver = "postgres"`.
        '';
      };

      name = lib.mkOption {
        type    = lib.types.str;
        default = "shlink";
        description = "Database name.";
      };

      user = lib.mkOption {
        type    = lib.types.str;
        default = "shlink";
        description = "Database user.";
      };

      host = lib.mkOption {
        type    = lib.types.str;
        default = "localhost";
        description = "Database hostname. Ignored for SQLite.";
      };

      port = lib.mkOption {
        type    = lib.types.nullOr lib.types.port;
        default = null;
        description = "Database port. Uses the driver's standard port when `null`.";
      };

      unixSocket = lib.mkOption {
        type    = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/postgresql";
        description = "Connect via Unix socket instead of host/port (postgres, mysql, maria only).";
      };

      passwordFile = lib.mkOption {
        type    = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the database password.
          Sets `DB_PASSWORD_FILE`; never stored in the Nix store.
        '';
      };
    };

    # ── Redirects ───────────────────────────────────────────────────────
    redirects = {
      statusCode = lib.mkOption {
        type    = lib.types.enum [ 301 302 307 308 ];
        default = 302;
        description = "HTTP status code for short URL redirects.";
      };

      baseUrl = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://example.com";
        description = "Redirect target for the bare base URL. Shows a generic 404 page when `null`.";
      };

      invalidShortUrl = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Redirect target for unknown or expired short codes.";
      };

      regular404 = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Redirect target for all other unmatched paths.";
      };
    };

    # ── Visit tracking ──────────────────────────────────────────────────
    tracking = {
      disable = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Completely disable visit tracking.";
      };

      anonymizeRemoteAddr = lib.mkOption {
        type    = lib.types.bool;
        default = true;
        description = "Obfuscate visitor IP addresses before storing. Disable only if you have a legal basis to store raw IPs.";
      };

      orphanVisits = lib.mkOption {
        type    = lib.types.bool;
        default = true;
        description = "Track visits to unknown short codes (orphan visits).";
      };

      disableIp = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Skip IP address collection (implies no geolocation even if GeoLite is enabled).";
      };

      disableReferrer = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Skip referrer tracking.";
      };

      disableUA = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Skip user-agent tracking.";
      };
    };

    # ── GeoLite2 ────────────────────────────────────────────────────────
    geolite = {
      enable = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = ''
          Enable MaxMind GeoLite2 geolocation for visit tracking.

          When `false` (the default), no GeoLite2 key is passed to Shlink,
          geolocation is disabled inside the application, and the two
          associated systemd units (`shlink-geolite-update.{service,timer}`
          and `shlink-visits-locate.{service,timer}`) are not created.

          Set to `true` and provide either `licenseKey` (not recommended —
          ends up in the Nix store) or `licenseKeyFile` to activate.
        '';
      };

      licenseKey = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          MaxMind GeoLite2 license key as a plain string.
          **This value will be world-readable in the Nix store.**
          Prefer `licenseKeyFile` or passing `GEOLITE_LICENSE_KEY` via
          `environmentFiles`.
        '';
      };

      licenseKeyFile = lib.mkOption {
        type    = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/geolite-key";
        description = ''
          Path to a file containing the MaxMind GeoLite2 license key.
          Sets `GEOLITE_LICENSE_KEY_FILE`; never stored in the Nix store.
        '';
      };

      updateCalendar = lib.mkOption {
        type    = lib.types.str;
        default = "weekly";
        example = "Mon *-*-* 03:00:00";
        description = ''
          systemd `OnCalendar` expression for the GeoLite2 database update
          timer. Ignored when `geolite.enable = false`.
        '';
      };
    };

    # ── Redis ───────────────────────────────────────────────────────────
    redis = {
      servers = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        example = "tcp://127.0.0.1:6379";
        description = ''
          Comma-separated Redis server URIs. When `null` (the default),
          Shlink uses local APCu cache — sufficient for single-instance
          deployments.
        '';
      };

      sentinelService = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Redis Sentinel service name (only needed with Sentinel HA setup).";
      };
    };

    # ── Mercure ─────────────────────────────────────────────────────────
    mercure = {
      publicHubUrl = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Public Mercure hub URL for real-time visit push notifications to
          the Shlink web client. Leave `null` (the default) to disable.
        '';
      };

      internalHubUrl = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Internal Mercure hub URL. Falls back to `publicHubUrl` when `null`.";
      };

      jwtSecret = lib.mkOption {
        type    = lib.types.nullOr lib.types.str;
        default = null;
        description = "Mercure JWT secret. Prefer passing via `environmentFiles`.";
      };
    };

    # ── Secrets / extra env ─────────────────────────────────────────────
    environmentFiles = lib.mkOption {
      type    = lib.types.listOf lib.types.path;
      default = [];
      description = ''
        List of files in `KEY=VALUE` format whose contents are loaded into
        every Shlink systemd unit's environment. Use this to provide secrets
        (DB password, GeoLite key, Mercure JWT, …) without storing them in
        the Nix store.

        Shlink supports the `<VAR>_FILE` convention, so you can also write
        lines like `DB_PASSWORD_FILE=/run/secrets/db-password` in these files.
      '';
    };

    # ── php-fpm tunables ────────────────────────────────────────────────
    phpfpm.settings = lib.mkOption {
      type    = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = {};
      example = lib.literalExpression ''{ "pm.max_children" = 20; }'';
      description = "Extra php-fpm pool settings merged on top of the module's defaults.";
    };

    # ── nginx integration helper (computed, read-only) ──────────────────
    nginxLocations = lib.mkOption {
      readOnly    = true;
      type        = lib.types.attrsOf lib.types.anything;
      description = ''
        Pre-built nginx location block set for this Shlink instance.
        Assign directly to `services.nginx.virtualHosts."<domain>".locations`.
      '';
    };

    user = lib.mkOption {
      type    = lib.types.str;
      default = "shlink";
      description = "System user account that runs Shlink processes.";
    };

    group = lib.mkOption {
      type    = lib.types.str;
      default = "shlink";
      description = "System group for the Shlink user.";
    };
  };

  # ── Implementation ──────────────────────────────────────────────────────
  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.database.createLocally -> cfg.database.driver == "postgres";
        message   = "services.shlink.database.createLocally is only supported with driver = \"postgres\".";
      }
      {
        assertion = cfg.database.driver == "sqlite" -> !cfg.database.createLocally;
        message   = "services.shlink.database.createLocally cannot be used with the sqlite driver.";
      }
      {
        assertion = cfg.geolite.enable ->
          (cfg.geolite.licenseKey != null || cfg.geolite.licenseKeyFile != null
           || cfg.environmentFiles != []);
        message = ''
          services.shlink.geolite.enable = true but no license key source is
          configured. Set geolite.licenseKeyFile, geolite.licenseKey, or pass
          GEOLITE_LICENSE_KEY / GEOLITE_LICENSE_KEY_FILE via environmentFiles.
        '';
      }
      {
        assertion = cfg.basePath == "" || lib.hasPrefix "/" cfg.basePath;
        message   = "services.shlink.basePath must be empty or start with \"/\".";
      }
    ];

    # ── System user & group ────────────────────────────────────────────
    users.users.${cfg.user} = {
      isSystemUser = true;
      group        = cfg.group;
      home         = stateDir;
      description  = "Shlink URL shortener service user";
    };

    users.groups.${cfg.group} = {};

    # ── State directories ──────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d ${stateDir}               0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/data          0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/data/cache    0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/data/locks    0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/data/log      0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/data/proxies  0750 ${cfg.user} ${cfg.group} - -"
      "d ${stateDir}/work          0750 ${cfg.user} ${cfg.group} - -"
    ];
    # ── Optional local PostgreSQL ──────────────────────────────────────
    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable          = lib.mkDefault true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers     = [{
        name              = cfg.database.user;
        ensureDBOwnership = true;
      }];
    };

    # ── php-fpm pool ───────────────────────────────────────────────────
    services.phpfpm.pools.${poolName} = {
      user        = cfg.user;
      group       = cfg.group;
      phpPackage  = phpWithExts;

      settings = lib.mkMerge [
        {
          "listen.owner"         = config.services.nginx.user;
          "listen.group"         = config.services.nginx.group;
          "listen.mode"          = "0660";
          "pm"                   = "dynamic";
          "pm.max_children"      = 10;
          "pm.start_servers"     = 2;
          "pm.min_spare_servers" = 1;
          "pm.max_spare_servers" = 5;
          "pm.max_requests"      = 500;
          # Allow Shlink env vars set in the systemd unit to reach workers.
          "clear_env"            = false;
        }
        cfg.phpfpm.settings
      ];

      phpEnv = fullEnv;
    };

    # ── Database init / migration oneshot ─────────────────────────────
    systemd.services.shlink-init = {
      description = "Shlink database initialisation and migration";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ]
                 ++ lib.optional cfg.database.createLocally "postgresql.service";
      requires    = lib.optional cfg.database.createLocally "postgresql.service";
      before      = [ "phpfpm-${poolName}.service" ];

      environment = fullEnv;

      serviceConfig = hardenedServiceConfig // {
        Type            = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "${stateDir}/work";
      };

      script = ''
        set -euo pipefail
        work="${stateDir}/work"
        pkg="${shlinkPkg}/share/php/shlink"

        # Populate the writable work dir with symlinks into the store.
        # SHLINK_WORK_DIR (set in environment) points here so that
        # container.php's chdir() lands in a writable tree.
        # data/ is the only directory replaced by the real writable copy.
        for entry in "$pkg"/*/; do
          name=$(basename "$entry")
          [ "$name" = "data" ] && continue
          ln -sfn "$entry" "$work/$name"
        done
        ln -sfn "${stateDir}/data" "$work/data"

        # Drop the config cache so a stale serialised config from a previous
        # run (or a previous package version) is never used.
        rm -f "${stateDir}/data/cache/app_config.php"

        php="${phpWithExts}/bin/php"
        cli="$pkg/bin/cli"

        echo "shlink-init: running db:create..."
        "$php" "$cli" db:create --no-interaction || true

        echo "shlink-init: running db:migrate..."
        "$php" "$cli" db:migrate --no-interaction
      '';
    };

    # Make php-fpm wait for the init service on every boot.
    systemd.services."phpfpm-${poolName}" = {
      after    = [ "shlink-init.service" ];
      requires = [ "shlink-init.service" ];
    };

    # ── GeoLite2 update timer (only when geolocation is enabled) ──────
    systemd.services.shlink-geolite-update = lib.mkIf cfg.geolite.enable {
      description = "Shlink: download updated GeoLite2 database";
      after       = [ "network-online.target" "shlink-init.service" ];
      wants       = [ "network-online.target" ];
      environment = fullEnv;

      serviceConfig = hardenedServiceConfig // {
        Type             = "oneshot";
        WorkingDirectory = "${stateDir}/work";
      };

      script = ''
        ${phpWithExts}/bin/php ${shlinkPkg}/share/php/shlink/bin/cli geolite:download-db --no-interaction
      '';
    };

    systemd.timers.shlink-geolite-update = lib.mkIf cfg.geolite.enable {
      description = "Shlink: periodic GeoLite2 database update";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar        = cfg.geolite.updateCalendar;
        Persistent        = true;
        RandomizedDelaySec = "1h";
      };
    };

    # ── Visit geolocation timer (only when geolocation is enabled) ────
    systemd.services.shlink-visits-locate = lib.mkIf cfg.geolite.enable {
      description = "Shlink: resolve geolocation for pending visits";
      after       = [ "network-online.target" "shlink-init.service" ];
      wants       = [ "network-online.target" ];
      requires    = [ "shlink-init.service" ];
      environment = fullEnv;

      serviceConfig = hardenedServiceConfig // {
        Type             = "oneshot";
        WorkingDirectory = "${stateDir}/work";
      };

      script = ''
        ${phpWithExts}/bin/php ${shlinkPkg}/share/php/shlink/bin/cli visit:locate --no-interaction
      '';
    };

    systemd.timers.shlink-visits-locate = lib.mkIf cfg.geolite.enable {
      description = "Shlink: geolocate visits every 30 minutes";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar        = "*:0/30";
        Persistent        = true;
        RandomizedDelaySec = "2m";
      };
    };

    # ── nginx helper locations (computed read-only option) ─────────────
    services.shlink.nginxLocations = {
      "/" = {
        root     = "${shlinkPkg}/share/php/shlink/public";
        index    = "index.php";
        tryFiles = "$uri $uri/ /index.php$is_args$args";
      };

      "~ \\.php$" = {
        root        = "${shlinkPkg}/share/php/shlink/public";
        extraConfig = ''
          fastcgi_pass  unix:${config.services.phpfpm.pools.${poolName}.socket};
          fastcgi_index index.php;
          fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
          fastcgi_split_path_info        ^(.+\.php)(/.*)$;
          fastcgi_param PATH_INFO        $fastcgi_path_info;
          include                        ${config.services.nginx.package}/conf/fastcgi_params;
          fastcgi_param HTTP_X_FORWARDED_FOR   $proxy_add_x_forwarded_for;
          fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;
        '';
      };

      "~ /\\." = {
        extraConfig = "deny all;";
      };
    };

    # nginx needs to read the fpm socket, which is owned by cfg.group.
    users.users.${config.services.nginx.user}.extraGroups = [ cfg.group ];

    # ── CLI wrapper ───────────────────────────────────────────────────────
    # Provides `shlink-cli` that runs the Shlink CLI with the correct
    # environment. Must be executed as the shlink user:
    #   sudo -u shlink shlink-cli api-key:generate
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "shlink-cli" ''
        if [ "$(id -u)" != "$(id -u ${cfg.user})" ] && [ "$(id -u)" != "0" ]; then
          echo "shlink-cli: run as ${cfg.user} or root" >&2
          exit 1
        fi

        # Export static env vars baked in at build time.
        ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") (shlinkEnv // nixEnv))}

        # Source any secret environment files at runtime so secrets never
        # end up in the Nix store.
        ${lib.concatMapStrings (f: ''
          if [ -r ${lib.escapeShellArg f} ]; then
            set -a; . ${lib.escapeShellArg f}; set +a
          fi
        '') cfg.environmentFiles}

        exec ${phpWithExts}/bin/php \
          ${shlinkPkg}/share/php/shlink/bin/cli "$@"
      '')
    ];
  };
}
